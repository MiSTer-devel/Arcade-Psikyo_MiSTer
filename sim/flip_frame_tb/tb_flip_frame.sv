`timescale 1ns/1ps
// Renders one captured game frame through the production psikyo_core and
// writes the visible 320x224 picture, so the Flip Screen DIP can be checked
// against the unflipped render: flipped must be the unflipped frame rotated
// 180 degrees, exactly (compare.py).
//
// Inputs come from make_frame.py: the gfx ROM regions as the SDRAM holds them,
// and a 68020 program that writes the MAME-captured sprite RAM, palette,
// VRAMs, vregs and SH404 bank register through the real CPU bus. The ROM
// models follow each port's contract (psikyo_sdram_top.sv): gfx rows are 8
// bytes MSB-first from the byte address, spritelut words are little-endian
// at twice the word address.
//
//   vsim -c tb_flip_frame +dir=run/gunbird_f02700 +flip=1 -do "run -all; quit -f"
//
// The picture is sampled the way the framework samples it: on ce_pix, with
// hblank/vblank low, pixel (hcnt, vcnt) = rgb.
module tb_flip_frame;

	logic clk = 0;
	always #5 clk = ~clk;
	logic reset, video_reset;

	logic [3:0] ce_cnt = 0;
	wire ce_pix = (ce_cnt == 0);
	always_ff @(posedge clk) ce_cnt <= (ce_cnt == 11) ? 4'd0 : ce_cnt + 4'd1;

	string dir;
	int    flip;
	logic  board_gunbird, board_sh404;

	logic         cpu_rom_req, cpu_rom_valid;
	logic [18:0] cpu_rom_addr;
	logic [15:0] cpu_rom_data;
	logic         l0_req, l1_req, sp_req, lut_req;
	logic         l0_valid, l1_valid, sp_valid, lut_valid;
	logic [21:0] l0_addr, l1_addr;
	logic [22:0] sp_addr;
	logic [16:0] lut_addr;
	logic [63:0] l0_data, l1_data, sp_data;
	logic [15:0] lut_data;
	logic [8:0]  hcnt, vcnt;
	logic         hblank, vblank, hsync, vsync;
	logic [14:0] rgb;

	psikyo_core #(.BOARD_GUNBIRD(1'b0), .DEBUG_TRACER(1'b0)) dut (
		.clk(clk), .ce_pix(ce_pix), .reset(reset), .video_reset(video_reset),
		.cpu_rom_req(cpu_rom_req), .cpu_rom_addr(cpu_rom_addr),
		.cpu_rom_valid(cpu_rom_valid), .cpu_rom_data(cpu_rom_data),
		.l0_gfxrom_req(l0_req), .l0_gfxrom_addr(l0_addr), .l0_gfxrom_valid(l0_valid), .l0_gfxrom_data(l0_data),
		.l1_gfxrom_req(l1_req), .l1_gfxrom_addr(l1_addr), .l1_gfxrom_valid(l1_valid), .l1_gfxrom_data(l1_data),
		.sp_gfxrom_req(sp_req), .sp_gfxrom_addr(sp_addr), .sp_gfxrom_valid(sp_valid), .sp_gfxrom_data(sp_data),
		.sp_lut_req(lut_req), .sp_lut_addr(lut_addr), .sp_lut_valid(lut_valid), .sp_lut_data(lut_data),
		.p1p2_in(32'hFFFFFFFF), .dsw_in(flip ? 32'hFFFEFFFF : 32'hFFFFFFFF), .coin_in(32'hFFFFFFFF),
		.board_gunbird(board_gunbird), .board_sh404(board_sh404), .snd_latch_c00011(1'b0),
		.mcu_table_absent(1'b1), .mcu_table_we(1'b0), .mcu_table_waddr(8'd0), .mcu_table_wdata(8'd0),
		.hs_address(17'd0), .hs_data_in(8'd0), .hs_data_out(), .hs_read(1'b0), .hs_write(1'b0),
		.latch_data(), .latch_write(),
		.hcnt(hcnt), .vcnt(vcnt), .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync), .rgb(rgb),
		.dbg_overlay(1'b0), .dbg_render_dis(3'd0), .pause(1'b0), .dbg_src(2'd0),
		.adpcma_req_i(1'b0), .adpcma_valid_i(1'b0), .adpcmb_req_i(1'b0), .adpcmb_valid_i(1'b0),
		.adpcma_late_i(1'b0), .adpcma_late_cnt_i(20'd0),
		.snd_l_i(16'sd0), .snd_r_i(16'sd0), .snd_tick_i(1'b0),
		.dbg_window(4'd0), .dbg_rearm(1'b0), .dbg_pixel()
	);

	// ---- memories ----
	logic [7:0] cpu_mem [0:1048575];
	logic [7:0] spr_mem [0:8388607];
	logic [7:0] til_mem [0:4194303];
	logic [7:0] lut_mem [0:262143];

	// ---- req/valid ROM models: capture the address on req, answer LAT
	// cycles later. A client may hold req until valid (the tilemap engines
	// do); a new transaction starts only once the previous one is answered.
	int cpu_cnt = 0, l0_cnt = 0, l1_cnt = 0, sp_cnt = 0, lut_cnt = 0;
	logic [18:0] cpu_a;
	logic [21:0] l0_a, l1_a;
	logic [22:0] sp_a;
	logic [16:0] lut_a;

	always_ff @(posedge clk) begin
		cpu_rom_valid <= 1'b0;
		if (reset) cpu_cnt <= 0;
		else if (cpu_cnt == 0) begin
			if (cpu_rom_req && !cpu_rom_valid) begin cpu_a <= cpu_rom_addr; cpu_cnt <= 3; end
		end else begin
			if (cpu_cnt == 1) begin
				cpu_rom_data  <= {cpu_mem[{cpu_a, 1'b0}], cpu_mem[{cpu_a, 1'b1}]};
				cpu_rom_valid <= 1'b1;
			end
			cpu_cnt <= cpu_cnt - 1;
		end
	end

	always_ff @(posedge clk) begin
		l0_valid <= 1'b0;
		if (reset) l0_cnt <= 0;
		else if (l0_cnt == 0) begin
			if (l0_req && !l0_valid) begin l0_a <= l0_addr; l0_cnt <= 3; end
		end else begin
			if (l0_cnt == 1) begin
				l0_data  <= {til_mem[l0_a], til_mem[l0_a+1], til_mem[l0_a+2], til_mem[l0_a+3],
				             til_mem[l0_a+4], til_mem[l0_a+5], til_mem[l0_a+6], til_mem[l0_a+7]};
				l0_valid <= 1'b1;
			end
			l0_cnt <= l0_cnt - 1;
		end
	end

	always_ff @(posedge clk) begin
		l1_valid <= 1'b0;
		if (reset) l1_cnt <= 0;
		else if (l1_cnt == 0) begin
			if (l1_req && !l1_valid) begin l1_a <= l1_addr; l1_cnt <= 3; end
		end else begin
			if (l1_cnt == 1) begin
				l1_data  <= {til_mem[l1_a], til_mem[l1_a+1], til_mem[l1_a+2], til_mem[l1_a+3],
				             til_mem[l1_a+4], til_mem[l1_a+5], til_mem[l1_a+6], til_mem[l1_a+7]};
				l1_valid <= 1'b1;
			end
			l1_cnt <= l1_cnt - 1;
		end
	end

	always_ff @(posedge clk) begin
		sp_valid <= 1'b0;
		if (reset) sp_cnt <= 0;
		else if (sp_cnt == 0) begin
			if (sp_req && !sp_valid) begin sp_a <= sp_addr; sp_cnt <= 4; end
		end else begin
			if (sp_cnt == 1) begin
				sp_data  <= {spr_mem[sp_a], spr_mem[sp_a+1], spr_mem[sp_a+2], spr_mem[sp_a+3],
				             spr_mem[sp_a+4], spr_mem[sp_a+5], spr_mem[sp_a+6], spr_mem[sp_a+7]};
				sp_valid <= 1'b1;
			end
			sp_cnt <= sp_cnt - 1;
		end
	end

	always_ff @(posedge clk) begin
		lut_valid <= 1'b0;
		if (reset) lut_cnt <= 0;
		else if (lut_cnt == 0) begin
			if (lut_req && !lut_valid) begin lut_a <= lut_addr; lut_cnt <= 4; end
		end else begin
			if (lut_cnt == 1) begin
				lut_data  <= {lut_mem[{lut_a, 1'b1}], lut_mem[{lut_a, 1'b0}]};
				lut_valid <= 1'b1;
			end
			lut_cnt <= lut_cnt - 1;
		end
	end

	int fd, n;
	logic [14:0] pic [0:223][0:319];
	int frames;

	initial begin
		if (!$value$plusargs("dir=%s", dir)) dir = ".";
		if (!$value$plusargs("flip=%d", flip)) flip = 0;
		fd = $fopen({dir, "/board.txt"}, "r");
		n = $fscanf(fd, "%d %d", board_gunbird, board_sh404);
		$fclose(fd);

		fd = $fopen({dir, "/cpu_rom.bin"}, "rb");   n = $fread(cpu_mem, fd); $fclose(fd);
		$display("cpu_rom %0d bytes", n);
		fd = $fopen({dir, "/sprites.bin"}, "rb");   n = $fread(spr_mem, fd); $fclose(fd);
		$display("sprites %0d bytes", n);
		fd = $fopen({dir, "/tiles.bin"}, "rb");     n = $fread(til_mem, fd); $fclose(fd);
		$display("tiles   %0d bytes", n);
		fd = $fopen({dir, "/lut.bin"}, "rb");       n = $fread(lut_mem, fd); $fclose(fd);
		$display("lut     %0d bytes", n);

		reset = 1; video_reset = 1;
		repeat (200) @(posedge clk);
		reset = 0; video_reset = 0;

		// loader finished: it writes 0xF11F to work RAM word 0 last
		wait (dut.u_workram.mem[0] == 16'hF11F);
		$display("[%0t] loader done", $time);

		// Frame boundaries: the first latches the DIP and builds the sprite
		// list from the pre-load snapshot, then copies live sprite RAM in;
		// the second builds from the loaded sprites. Render the frame after.
		frames = 0;
		while (frames < 3) begin
			@(negedge clk iff dut.frame_start);
			frames++;
		end
		// Sample at negedge: every posedge update has settled, and the values
		// are the ones the framework registers at the next ce_pix edge.
		@(negedge clk iff (ce_pix && vcnt == 9'd261 && hcnt == 9'd455));
		forever begin
			@(negedge clk);
			if (ce_pix && !hblank && !vblank) pic[vcnt][hcnt] = rgb;
			if (ce_pix && vcnt == 9'd223 && hcnt == 9'd319) break;
		end

		fd = $fopen($sformatf("%s/core_flip%0d.ppm", dir, flip), "w");
		$fwrite(fd, "P3\n320 224\n31\n");
		for (int y = 0; y < 224; y++) begin
			for (int x = 0; x < 320; x++)
				$fwrite(fd, "%0d %0d %0d ", pic[y][x][14:10], pic[y][x][9:5], pic[y][x][4:0]);
			$fwrite(fd, "\n");
		end
		$fclose(fd);
		$display("[%0t] wrote %s/core_flip%0d.ppm (flip_screen=%b)", $time, dir, flip, dut.flip_screen);
		$finish;
	end

	initial begin
		#3_000_000_000;
		$display("FAIL: watchdog timeout");
		$finish;
	end
endmodule
