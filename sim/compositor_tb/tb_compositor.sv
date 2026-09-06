// Checks compositor against an independently-computed reference. Cases
// chosen to isolate specific risks rather than one big combined scenario:
// basic layer-only draws, transparent-pen skip, opaque-mode override,
// layer-disable, the sprite priority-mask table's "always front"/"always
// behind" behavior (including the easy-to-miss case where a "behind"
// sprite still shows through when NEITHER tilemap layer drew anything),
// and the screen-clear/backdrop rule ported from MAME PR 16050
// ("psikyo.cpp: Fix background colour"), including three vectors taken
// straight from the real control-word values psikyo_v.cpp records in its
// own comment block.

module tb_compositor;

	logic         l0_valid;
	logic [3:0]  l0_pixel;
	logic [6:0]  l0_color;
	logic         l0_ctrl_enable, l0_ctrl_opaque, l0_ctrl_transpen_sel, l0_ctrl_bg_pen15;

	logic         l1_valid;
	logic [3:0]  l1_pixel;
	logic [6:0]  l1_color;
	logic         l1_ctrl_enable, l1_ctrl_opaque, l1_ctrl_transpen_sel, l1_ctrl_bg_pen15;

	logic         sp_present;
	logic [3:0]  sp_pixel;
	logic [4:0]  sp_color;
	logic [1:0]  sp_priority;

	logic [11:0] pal_addr;
	logic [8:0]  pal_s_addr;
	logic         sprite_sel;
	logic         backdrop_black;

	compositor dut (.*);

	int errors;

	// bgp15 (control bit 2, inverted) defaults to 0 = "bit 2 set" = this
	// layer offers no pen-15 clear colour, which is the quiet choice for
	// every case below that is not specifically about the screen clear.
	task automatic set_l0(int valid, int pixel, int color, int en, int op, int tsel, int bgp15 = 0);
		l0_valid = valid[0]; l0_pixel = pixel[3:0]; l0_color = color[6:0];
		l0_ctrl_enable = en[0]; l0_ctrl_opaque = op[0]; l0_ctrl_transpen_sel = tsel[0];
		l0_ctrl_bg_pen15 = bgp15[0];
	endtask

	task automatic set_l1(int valid, int pixel, int color, int en, int op, int tsel, int bgp15 = 0);
		l1_valid = valid[0]; l1_pixel = pixel[3:0]; l1_color = color[6:0];
		l1_ctrl_enable = en[0]; l1_ctrl_opaque = op[0]; l1_ctrl_transpen_sel = tsel[0];
		l1_ctrl_bg_pen15 = bgp15[0];
	endtask

	// Drive a layer's control inputs from a REAL 16-bit layer_ctrl word,
	// decoded exactly as vreg_decode.sv does it, so the screen-clear cases
	// below can quote psikyo_v.cpp's recorded per-game values verbatim
	// instead of restating them as already-decoded booleans.
	//
	// The pixel is forced to the layer's own transparent pen (bit 3 set -> 0,
	// clear -> 15), i.e. "this layer is on but this pixel is a hole", which is
	// precisely the situation the screen clear shows through. That holds only
	// while opaque (bit 1) is clear, which it is in every word quoted below.
	task automatic set_l0_ctrl(int ctrl);
		set_l0(1, ctrl[3] ? 0 : 15, 0, ~ctrl[0], ctrl[1], ctrl[3], ~ctrl[2]);
	endtask

	task automatic set_l1_ctrl(int ctrl);
		set_l1(1, ctrl[3] ? 0 : 15, 0, ~ctrl[0], ctrl[1], ctrl[3], ~ctrl[2]);
	endtask

	task automatic set_sp(int present, int pixel, int color, int pri);
		sp_present = present[0]; sp_pixel = pixel[3:0]; sp_color = color[4:0]; sp_priority = pri[1:0];
	endtask

	// tilemap/backdrop wins: the LIVE palette lookup must carry exp_addr
	// and sprite_sel must be low. backdrop_black must be low too -- a real
	// palette entry is being named, so the black fallback must not also be
	// asserted (it would override this address at psikyo_core's RGB mux and
	// the checked pal_addr would never reach the screen).
	task automatic check(string label, int exp_addr);
		#1;
		if (sprite_sel !== 1'b0) begin
			errors++;
			$display("FAIL(%s) sprite_sel: got=1 expected=0", label);
		end
		if (backdrop_black !== 1'b0) begin
			errors++;
			$display("FAIL(%s) backdrop_black: got=1 expected=0", label);
		end
		if (pal_addr !== exp_addr[11:0]) begin
			errors++;
			$display("FAIL(%s) pal_addr: got=%h expected=%h", label, pal_addr, exp_addr);
		end
	endtask

	// MAME's black_pen() fallback: no layer offers a clear colour, so the
	// pixel is forced black at psikyo_core's RGB mux and pal_addr is a
	// don't-care (deliberately NOT checked here).
	task automatic check_black(string label);
		#1;
		if (sprite_sel !== 1'b0) begin
			errors++;
			$display("FAIL(%s) sprite_sel: got=1 expected=0", label);
		end
		if (backdrop_black !== 1'b1) begin
			errors++;
			$display("FAIL(%s) backdrop_black: got=0 expected=1", label);
		end
	endtask

	// sprite wins: the SNAPSHOT palette lookup must carry exp_addr and
	// sprite_sel must be high (the caller muxes the RAM outputs on it).
	task automatic check_sp(string label, int exp_addr);
		#1;
		if (sprite_sel !== 1'b1) begin
			errors++;
			$display("FAIL(%s) sprite_sel: got=0 expected=1", label);
		end
		if (pal_s_addr !== exp_addr[8:0]) begin
			errors++;
			$display("FAIL(%s) pal_s_addr: got=%h expected=%h", label, pal_s_addr, exp_addr);
		end
	endtask

	initial begin
		errors = 0;

		// ---- Case 1: only layer0 opaque, non-transparent pixel ----
		set_l0(1, 5, 3, 1, 0, 0);   // transpen=15 (tsel=0), pixel=5 != 15 -> draws
		set_l1(0, 0, 0, 0, 0, 0);
		set_sp(0, 0, 0, 0);
		check("l0-only", 12'h800 + 3*16 + 5);

		// ---- Case 2: layer0 transparent (pixel==transpen), layer1 opaque wins ----
		set_l0(1, 15, 3, 1, 0, 0);   // transpen=15, pixel==15 -> does NOT draw
		set_l1(1, 7, 2, 1, 0, 1);    // transpen=0 (tsel=1), pixel=7 != 0 -> draws
		set_sp(0, 0, 0, 0);
		check("l1-wins-l0-transparent", 12'h800 + 2*16 + 7);

		// ---- Case 3: layer0 opaque-mode forces draw even at transparent pixel ----
		set_l0(1, 15, 4, 1, 1, 0);   // transpen=15, pixel==15, but opaque=1 -> draws anyway
		set_l1(0, 0, 0, 0, 0, 0);
		set_sp(0, 0, 0, 0);
		check("l0-opaque-forced", 12'h800 + 4*16 + 15);

		// ---- Case 4: layer0 disabled even with non-transparent pixel ----
		set_l0(1, 5, 3, 0, 0, 0);    // ctrl_enable=0 -> does NOT draw regardless of pixel
		set_l1(0, 0, 0, 0, 0, 0);
		set_sp(0, 0, 0, 0);
		// Falls through to the screen clear. Both layers are disabled, so
		// under MAME PR 16050 no layer contributes a clear colour and the
		// fallback is black_pen() -- not palette[0x800], which is what this
		// case expected before the port.
		check_black("l0-disabled-backdrop-black");

		// ---- Case 5: sprite priority 0 -- always front, wins over both opaque layers ----
		set_l0(1, 5, 3, 1, 0, 0);
		set_l1(1, 7, 2, 1, 0, 1);
		set_sp(1, 9, 6, 0);
		check_sp("sprite-priority0-front", 6*16 + 9);

		// Cases 6-9 encode the BIT-INDEXED primask semantics (MAME's
		// pdrawgfx convention: sprite blocked iff primask[priority_val]),
		// fixed 2026-08-29. The original value-AND implementation --
		// (priority_val & primask) == 0 -- passed an earlier version of
		// these cases while rendering samuraia's priority-1 cloud sprites
		// over tilemap 1 on hardware: layer 1's priority_val of 2 ANDs to
		// zero against 0xFC. The tests below fail against value-AND.

		// ---- Case 6: sprite priority 1 (0xFC) -- above layer 0 ----
		set_l0(1, 5, 3, 1, 0, 0);
		set_l1(0, 0, 0, 0, 0, 0);
		set_sp(1, 9, 6, 1);
		check_sp("sprite-priority1-wins-over-l0-only", 6*16 + 9);

		// ---- Case 6b: sprite priority 1 -- BELOW layer 1 (the samuraia
		// cloud case: primask[2] of 0xFC is set, layer 1 wins) ----
		set_l0(0, 0, 0, 0, 0, 0);
		set_l1(1, 7, 2, 1, 0, 1);
		set_sp(1, 9, 6, 1);
		check("sprite-priority1-blocked-by-l1", 12'h800 + 2*16 + 7);

		// ---- Case 6c: priority 1, both layers drawing -- layer 1 on top
		// (priority_val=2), sprite still blocked ----
		set_l0(1, 5, 3, 1, 0, 0);
		set_l1(1, 7, 2, 1, 0, 1);
		set_sp(1, 9, 6, 1);
		check("sprite-priority1-blocked-by-l1-over-l0", 12'h800 + 2*16 + 7);

		// ---- Case 7: sprite priority 2 (0xFE) -- blocked by layer 0 alone
		// (primask[1] set), unlike priority 1 ----
		set_l0(1, 5, 3, 1, 0, 0);
		set_l1(0, 0, 0, 0, 0, 0);
		set_sp(1, 9, 6, 2);
		check("sprite-priority2-blocked-by-l0", 12'h800 + 3*16 + 5);

		// ---- Case 7b: sprite priority 2 -- blocked by layer 1 alone ----
		set_l0(0, 0, 0, 0, 0, 0);
		set_l1(1, 7, 2, 1, 0, 1);
		set_sp(1, 9, 6, 2);
		check("sprite-priority2-blocked-by-l1-only", 12'h800 + 2*16 + 7);

		// ---- Case 7c: sprite priority 2 -- visible over BARE BACKDROP
		// (primask[0] of 0xFE is clear; this is what distinguishes 0xFE
		// from published MAME's 0xFF for this entry) ----
		set_l0(0, 0, 0, 0, 0, 0);
		set_l1(0, 0, 0, 0, 0, 0);
		set_sp(1, 9, 6, 2);
		check_sp("sprite-priority2-wins-over-backdrop", 6*16 + 9);

		// ---- Case 8: sprite priority 3 (0xFF) -- blocked by layer 1 ----
		set_l0(0, 0, 0, 0, 0, 0);
		set_l1(1, 7, 2, 1, 0, 1);
		set_sp(1, 9, 6, 3);
		check("sprite-priority3-blocked-by-l1", 12'h800 + 2*16 + 7);

		// ---- Case 8b: sprite priority 3 -- blocked by layer 0 alone ----
		set_l0(1, 5, 3, 1, 0, 0);
		set_l1(0, 0, 0, 0, 0, 0);
		set_sp(1, 9, 6, 3);
		check("sprite-priority3-blocked-by-l0-too", 12'h800 + 3*16 + 5);

		// ---- Case 8c: sprite priority 3 -- NEVER visible: primask[0] of
		// 0xFF is set, so even bare backdrop blocks it. With both layers
		// disabled the backdrop it loses to is the black fallback ----
		set_l0(0, 0, 0, 0, 0, 0);
		set_l1(0, 0, 0, 0, 0, 0);
		set_sp(1, 9, 6, 3);
		check_black("sprite-priority3-never-visible");

		// ---- Case 9: sprite priority 1, neither layer drew -- primask[0]
		// of 0xFC is clear, sprite wins over backdrop ----
		set_l0(1, 15, 0, 1, 0, 0);   // transparent
		set_l1(1, 0, 0, 1, 0, 1);    // transparent (transpen=0, pixel=0)
		set_sp(1, 9, 6, 1);
		check_sp("sprite-priority1-wins-over-backdrop", 6*16 + 9);

		// ================= SCREEN CLEAR / BACKDROP =================
		// Cases 10-20 encode MAME PR 16050's screen-clear loop:
		//
		//   bgpen = black_pen();
		//   for (layer = 0..1)
		//     if (~ctrl[layer] & 1) {            // enabled
		//       if (~ctrl[layer] & 8) bgpen = pen(base[layer] + 0x00);
		//       if (~ctrl[layer] & 4) bgpen = pen(base[layer] + 0x0f);
		//     }
		//
		// Later writes overwrite earlier ones, so precedence runs layer 1
		// pen 15 > layer 1 pen 0 > layer 0 pen 15 > layer 0 pen 0 > black.
		// base[] is 0x800 (layer 0) / 0xC00 (layer 1) here, NOT the PR's
		// 0x400/0x800 -- see compositor.sv's note on that constant.
		//
		// Four behaviours below did not exist before the port, and each of
		// these cases fails against the previous "topmost enabled layer, its
		// transpen-selected pen, else 0x800" rule.

		// ---- Case 10: neither layer enabled -> BLACK, not palette[0x800].
		// Previously this returned 0x800 whatever the control bits said ----
		set_l0(0, 0, 0, 0, 0, 0);
		set_l1(0, 0, 0, 0, 0, 0);
		set_sp(0, 0, 0, 0);
		check_black("backdrop-both-disabled-black");

		// ---- Case 11: still black with the transparent-pen bits set both
		// ways -- a disabled layer contributes nothing at all ----
		set_l0(0, 0, 0, /*en=*/0, 0, /*tsel=*/1, /*bgp15=*/1);
		set_l1(0, 0, 0, /*en=*/0, 0, /*tsel=*/0, /*bgp15=*/1);
		check_black("backdrop-disabled-ignores-pen-bits");

		// ---- Case 12: ENABLED but with both control bits 3 and 2 set, so
		// neither pen is offered -> black. "Enabled" alone is no longer
		// enough to put a colour on screen ----
		set_l0(1, 0, 3, /*en=*/1, 0, /*tsel=*/1, /*bgp15=*/0);
		set_l1(1, 0, 2, /*en=*/1, 0, /*tsel=*/1, /*bgp15=*/0);
		check_black("backdrop-enabled-but-no-pen-offered-black");

		// ---- Case 13: layer 0 alone, bit 3 clear -> its pen 0 (0x400) ----
		// The clear bases are layer*0x400 + 0x400, per MAME PR 16050 -- NOT
		// the 0x800/0xC00 banks the layers draw from. See compositor.sv for
		// why the two are deliberately different.
		set_l0(1, 15, 3, 1, 0, /*tsel=*/0, /*bgp15=*/0);
		set_l1(0, 0, 0, 0, 0, 0);
		check("backdrop-l0-pen0", 12'h400);

		// ---- Case 14: layer 0 alone, bit 2 clear -> its pen 15 (0x40F) ----
		set_l0(1, 0, 3, 1, 0, /*tsel=*/1, /*bgp15=*/1);
		check("backdrop-l0-pen15", 12'h40F);

		// ---- Case 15: layer 0 with BOTH bits clear -- the pen-15 write
		// comes second in MAME's loop, so it overwrites pen 0 ----
		set_l0(1, 15, 3, 1, 0, /*tsel=*/0, /*bgp15=*/1);
		check("backdrop-l0-pen15-overrides-pen0", 12'h40F);

		// ---- Case 16: layer 1's clear base is 0x800 (layer*0x400 + 0x400),
		// same two pens. Note this is layer 0's DRAWING bank, not layer 1's --
		// the clear bases and the drawing banks are offset by one 0x400 bank
		// from each other, which is what makes this worth an explicit case ----
		set_l0(0, 0, 0, 0, 0, 0);
		set_l1(1, 15, 2, 1, 0, /*tsel=*/0, /*bgp15=*/0);
		check("backdrop-l1-pen0", 12'h800);
		set_l1(1, 0, 2, 1, 0, /*tsel=*/1, /*bgp15=*/1);
		check("backdrop-l1-pen15", 12'h80F);

		// ---- Case 17: layer 1 runs last, so it overwrites layer 0's
		// choice when it has one of its own ----
		set_l0(1, 15, 3, 1, 0, /*tsel=*/0, /*bgp15=*/1);   // would give 0x40F
		set_l1(1, 15, 2, 1, 0, /*tsel=*/0, /*bgp15=*/0);   // gives 0x800
		check("backdrop-l1-overrides-l0", 12'h800);

		// ---- Case 18: THE STRUCTURAL CHANGE. Layer 1 is enabled but offers
		// no pen (bits 3 and 2 both set), so layer 0's choice stands. The old
		// `else if (l1_ctrl_enable)` chain shut layer 0 out on layer 1's
		// enable bit alone and returned layer 1's base here ----
		set_l0(1, 15, 3, 1, 0, /*tsel=*/0, /*bgp15=*/0);   // offers pen 0
		set_l1(1, 0, 2, 1, 0, /*tsel=*/1, /*bgp15=*/0);    // offers nothing
		check("backdrop-l0-survives-enabled-but-silent-l1", 12'h400);

		// ---- Cases 19-20: real control words, quoted from psikyo_v.cpp's
		// own per-game comment block. These are the accuracy anchors ----

		// "gunbird: L:00d0-04d0" -- both layers enabled, bits 3 and 2 clear,
		// so both offer pen 15 and layer 1 wins.
		set_l0_ctrl(16'h00d0);
		set_l1_ctrl(16'h04d0);
		check("gunbird-L00d0-04d0", 12'h80F);

		// "gunbird: 00e1 04e1 ... for a blink, on scene transitions" -- bit 0
		// SET on both layers, i.e. both DISABLED. This is the blink, and it
		// is black under the new rule where it used to be palette[0x800].
		set_l0_ctrl(16'h00e1);
		set_l1_ctrl(16'h04e1);
		check_black("gunbird-blink-00e1-04e1-black");

		// "tengai: L:0178-0508 <-- Transpen is 0 as opposed to 15." Bit 3 is
		// set on both layers (hence transpen 0) but bit 2 is clear, so the
		// clear colour is pen 15 of layer 1's clear base. The old rule read
		// bit 3 as selecting pen 0 and returned that base's pen 0 instead.
		// Tengai is the ONLY game whose recorded control words distinguish
		// the two readings of bit 3 -- see docs/phase1_video_engine.md.
		set_l0_ctrl(16'h0178);
		set_l1_ctrl(16'h0508);
		check("tengai-L0178-0508", 12'h80F);

		// (The final RGB mux -- registered sprite_sel selecting between the
		// two palette RAMs' outputs -- lives in psikyo_core.sv, exercised
		// by the integration testbenches, not here.)

		if (errors == 0)
			$display("PASS: compositor matches reference for all cases");
		else
			$display("FAIL: %0d mismatches", errors);

		$finish;
	end

endmodule
