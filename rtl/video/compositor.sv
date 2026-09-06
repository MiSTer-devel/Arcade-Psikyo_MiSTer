// Final compositing stage: two live tilemap-layer pixel streams
// (tilemap_line_engine x2) + the sprite frame buffer's read port ->
// resolved palette index -> xRGB_555 RGB. Per-pixel priority mux, not a
// persisted priority bitmap -- see docs/phase1_video_engine.md,
// "Compositor: backdrop, transparent-pen, and palette lookup" for the full
// derivation (traced directly from screen_update()).
//
// The screen-clear/backdrop rule follows MAME PR 16050, "psikyo.cpp: Fix
// background colour", which replaced screen_update()'s dead `layers_ctrl`
// branch (a local hardcoded to -1, so only its first arm ever ran and the
// clear always came from layer 0) with a loop over both layers. See the
// backdrop mux at the bottom of this file for the exact translation.
//
// Sprite opacity needs no per-pixel check here: sprite_render_engine
// already applied trans_pen0/trans_pen15 before ever writing to the frame
// buffer, so sp_present alone means "opaque."
//
// Palette RAM (xRGB_555, 4096 entries) is a 1-cycle sync read port owned
// externally (shared with CPU-visible palette writes) -- this module
// computes pal_addr purely combinationally from its inputs; the 1-cycle
// latency comes entirely from the external palette memory's own read
// port (matching every other BRAM interface in this project), not from
// any register in here -- an earlier draft also registered `rgb` inside
// this module, which would have added a REDUNDANT second cycle of
// latency on top of the palette memory's own, silently doubling the
// pipeline depth. `rgb` is simply `pal_data[14:0]`. This module ends up
// entirely combinational (no clock, no registers) as a result.

module compositor (
	input logic         l0_valid,
	input logic [3:0]  l0_pixel,
	input logic [6:0]  l0_color,
	input logic         l0_ctrl_enable,        // layer_ctrl[0] bit 0
	input logic         l0_ctrl_opaque,        // layer_ctrl[0] bit 1
	input logic         l0_ctrl_transpen_sel,  // layer_ctrl[0] bit 3 (1 -> pen 0 transparent, 0 -> pen 15)
	input logic         l0_ctrl_bg_pen15,      // layer_ctrl[0] bit 2, INVERTED by vreg_decode
	                                            // (1 = bit clear = pen 15 is this layer's clear colour)

	input logic         l1_valid,
	input logic [3:0]  l1_pixel,
	input logic [6:0]  l1_color,
	input logic         l1_ctrl_enable,
	input logic         l1_ctrl_opaque,
	input logic         l1_ctrl_transpen_sel,
	input logic         l1_ctrl_bg_pen15,

	input logic         sp_present,
	input logic [3:0]  sp_pixel,
	input logic [4:0]  sp_color,
	input logic [1:0]  sp_priority,

	// Two palette lookups run in PARALLEL: tilemap/backdrop entries go to
	// the live palette RAM (pal_addr), sprite entries to the vblank
	// snapshot of the sprite half (pal_s_addr, entries 0x000-0x1FF) --
	// sprites display pixels rendered a frame earlier, so they must use a
	// palette from the same frame boundary or a scene change recolors the
	// previous scene's still-displayed sprites. sprite_sel says which
	// lookup wins THIS pixel; the caller applies it to the RAM outputs one
	// cycle later (BRAM read latency) and owns the final RGB mux.
	output logic [11:0] pal_addr,     // live palette: tilemap/backdrop entry
	output logic [8:0]  pal_s_addr,   // snapshot palette: sprite entry
	output logic         sprite_sel,   // 1 = sprite lookup wins this pixel

	// MAME's screen clear falls back to m_palette->black_pen() when neither
	// layer offers a clear colour. black_pen() is a dedicated entry appended
	// past the 0x1000 configured palette entries; this core's palette RAM is
	// exactly the 4096 CPU-writable entries with no spare, and every entry is
	// game-written, so there is no address that reliably reads back black.
	// The fallback is therefore signalled out of band and applied at the RGB
	// mux in psikyo_core.sv (which already force-blacks the two edge columns
	// the same way). pal_addr still holds a defined value while this is set.
	output logic         backdrop_black
);

	// ---- per-layer opacity ----
	logic [3:0]  l0_transpen, l1_transpen;
	logic         l0_draws, l1_draws;

	assign l0_transpen = l0_ctrl_transpen_sel ? 4'd0 : 4'd15;
	assign l1_transpen = l1_ctrl_transpen_sel ? 4'd0 : 4'd15;

	assign l0_draws = l0_valid && l0_ctrl_enable && (l0_ctrl_opaque || (l0_pixel != l0_transpen));
	assign l1_draws = l1_valid && l1_ctrl_enable && (l1_ctrl_opaque || (l1_pixel != l1_transpen));

	// ---- priority resolution + sprite gating ----
	logic [1:0] priority_val;
	assign priority_val = l1_draws ? 2'd2 : (l0_draws ? 2'd1 : 2'd0);

	// {0x00, 0xFC, 0xFE, 0xFF} -- table per the author of MAME's Psikyo
	// renderer (published psikyo_v.cpp reads {0,fc,ff,ff}; fe for field 2
	// makes it visible over backdrop where ff never draws).
	//
	// The mask is BIT-INDEXED by the destination priority value, exactly
	// MAME's pdrawgfx convention: the sprite pixel is BLOCKED when
	// primask[priority_val] is set. With this compositor's encoding
	// (0 = backdrop, 1 = layer 0 on top, 2 = layer 1 on top):
	//   pri 0 (0x00): above everything
	//   pri 1 (0xFC): bit1 clear, bit2 set -> above layer 0, below layer 1
	//   pri 2 (0xFE): bits 1-2 set        -> below both, visible on backdrop
	//   pri 3 (0xFF): bit0 also set       -> never visible
	//
	// BIT-INDEXED, never value-ANDed: (priority_val & primask) looks
	// plausible but is wrong for every entry except 0 -- layer 1's value 2
	// ANDs to zero against 0xFC, letting priority-1 sprites beat layer 1
	// unconditionally. tb_compositor's cases 6-9 fail against value-AND.
	logic [7:0] primask;
	always_comb begin
		unique case (sp_priority)
			2'd0: primask = 8'h00;
			2'd1: primask = 8'hFC;
			2'd2: primask = 8'hFE;
			2'd3: primask = 8'hFF;
		endcase
	end

	logic sprite_wins;
	assign sprite_wins = sp_present && !primask[{1'b0, priority_val}];

	// ---- palette address mux ----
	// tilemap: 0x800 + color*16 + pixel (color already includes layer 1's +64);
	// {color,pixel} concatenation IS color*16+pixel exactly since pixel is
	// always a 4-bit low nibble -- no actual multiply needed.
	// sprite:  0x000 + color*16 + pixel, same trick.
	// backdrop: see the screen-clear mux below.
	logic [10:0] l1_pal_offset, l0_pal_offset;   // color(7b)*16+pixel(4b), max 71*16+15=1151
	logic [8:0]  sp_pal_offset;                    // color(5b)*16+pixel(4b), max 31*16+15=511
	assign l1_pal_offset = {l1_color, l1_pixel};
	assign l0_pal_offset = {l0_color, l0_pixel};
	assign sp_pal_offset  = {sp_color, sp_pixel};

	assign pal_s_addr = sp_pal_offset;
	assign sprite_sel  = sprite_wins;

	// ---- backdrop / screen clear ----
	// MAME PR 16050 replaced the old dead-code `layers_ctrl` chain with:
	//
	//     bgpen = m_palette->black_pen();          // fallback
	//     for (int layer = 0; layer < 2; layer++)
	//         if (~layer_ctrl[layer] & 1)          // enabled
	//         {
	//             if (~layer_ctrl[layer] & 8)      // not transparent
	//                 bgpen = m_palette->pen(<layer base> + 0x00);
	//             if (~layer_ctrl[layer] & 4)      // not transparent
	//                 bgpen = m_palette->pen(<layer base> + 0x0f);
	//         }
	//
	// It is a sequence of overwrites, so the LAST assignment that fires wins.
	// Unrolled into a priority mux that is highest-precedence-first, the
	// order is exactly the reverse of the write order: layer 1's pen 15,
	// layer 1's pen 0, layer 0's pen 15, layer 0's pen 0, then black.
	//
	// A layer being enabled is no longer sufficient on its own: if both bits
	// 3 and 2 are set the layer contributes nothing and the next candidate
	// down applies. That is the one place this differs structurally from an
	// `else if (l1_ctrl_enable)` chain, which let an enabled layer 1 shut
	// layer 0 out even when it had no colour of its own to offer.
	//
	// PALETTE BASES MATCH PR 16050 EXACTLY: `m_palette->pen(layer*0x400 +
	// 0x400)` / `+ 0x40f`, so 0x400/0x40f for layer 0 and 0x800/0x80f for
	// layer 1.
	//
	// This core briefly used 0x800/0xC00 instead, on the reasoning that the
	// PR's bases sit one 0x400 bank below where the tiles' own palette lives:
	// gfx_psikyo gives the tiles GFXDECODE_ENTRY a colorbase of 0x800, and
	// get_tile_info adds Layer*0x40 colours (= 0x400 entries), so layer 0
	// draws from 0x800-0x87F and layer 1 from 0xC00-0xC7F, which made 0x400
	// look like an off-by-one-bank slip against the PR's own pre-image of
	// 0x800/0x80f.
	//
	// It is not a slip. Confirmed 2026-09-05 by the author of PR 16050, who
	// also wrote MAME's Psikyo renderer: 0x400 is intentional, and this core
	// follows MAME rather than the inference above. The clear colour is
	// simply not taken from the same bank the layer draws from.
	logic bd_l0_pen0, bd_l0_pen15, bd_l1_pen0, bd_l1_pen15;
	assign bd_l0_pen0  = l0_ctrl_enable && !l0_ctrl_transpen_sel; // bit 3 clear
	assign bd_l0_pen15 = l0_ctrl_enable &&  l0_ctrl_bg_pen15;     // bit 2 clear
	assign bd_l1_pen0  = l1_ctrl_enable && !l1_ctrl_transpen_sel;
	assign bd_l1_pen15 = l1_ctrl_enable &&  l1_ctrl_bg_pen15;

	// Gated on neither layer drawing, not just on the candidates being
	// absent: psikyo_core's RGB mux applies this ahead of pal_data, so an
	// ungated version would black out a perfectly good tile pixel whenever
	// the layer that drew it happened to offer no clear colour (an enabled
	// layer with control bits 3 and 2 both set does exactly that). Sprites
	// need no term here -- sprite_sel is tested first at that mux.
	assign backdrop_black = !l1_draws && !l0_draws &&
							!(bd_l0_pen0 || bd_l0_pen15 || bd_l1_pen0 || bd_l1_pen15);

	always_comb begin
		if (l1_draws)
			pal_addr = 12'h800 + {1'b0, l1_pal_offset};
		else if (l0_draws)
			pal_addr = 12'h800 + {1'b0, l0_pal_offset};
		else if (bd_l1_pen15) pal_addr = 12'h80F;
		else if (bd_l1_pen0)  pal_addr = 12'h800;
		else if (bd_l0_pen15) pal_addr = 12'h40F;
		else if (bd_l0_pen0)  pal_addr = 12'h400;
		// backdrop_black is set here; pal_addr just needs to stay defined
		// (psikyo_core.sv's debug snapshot latches it every pixel).
		else                   pal_addr = 12'h800;
	end

endmodule
