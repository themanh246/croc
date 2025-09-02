// ============================================================================
// ascon_controller.sv
// Controller for ASCON core, handling input/output from 32-bit OBI interface
// Supports AEAD (AD + MSG) processing
// ============================================================================
`include "include/config.sv"
`include "include/asconp.sv"
`include "include/functions.sv"

module ascon_controller #(
    // parameter CCW = 32 // CCW = 64 chi dung data 32bit 
) (
    input  logic          clk_i,
    input  logic          rst_ni,

    // From registers
    input  logic [127:0] key_i,          // 128-bit key from 2x32-bit words
    input  logic             key_valid_i,
    input  logic [127:0] nonce_i,        // 128-bit nonce from 2x32-bit words
    input  logic [31:0]      data_in_i,      // 32-bit input from reg block
    input  logic             data_in_valid_i,
    input  logic             start_enc_i,
    input  logic             start_dec_i,

    // To registers
    output logic [31:0]      data_out_o,     // 32-bit output to reg block
    output logic             data_out_valid_o,
    output logic             busy_o,
    output logic             auth_o,
    output logic             done_o
);

    // -------------------------
    // Signals to connect ASCON core
    // -------------------------
    logic [31:0] core_bdi; // old: logic [127:0] core_bdi;
    logic [3:0]   core_bdi_valid;
    e_data_type   core_bdi_type;
    logic         core_bdi_eot;
    logic         core_bdi_eoi;

    logic [31:0] core_bdo;		// old: logic [127:0] core_bdo;
    logic         core_bdo_valid;
    e_data_type   core_bdo_type;
    logic         core_bdo_eot;

    logic [127:0] core_key;
    logic [127:0] core_nonce;
    logic         core_key_valid;

    logic core_bdo_ready = 1'b1; // always ready in controller
    logic core_auth, core_auth_valid, core_done;

    // thêm counter để stream KEY 4x32b, hiện tại đầu vào key là 128, core chỉ nhận 32bit
	logic [1:0]         key_idx;
	logic               key_stream;
	// Thêm counter để stream NONCE 4x32b qua BDI
	logic [1:0]         nonce_idx;
	logic               nonce_stream;
	//////////////////////////////////////////
    // Latch mode
	logic               mode_enc;
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if (!rst_ni) mode_enc <= 1'b1;
		else if (!key_stream && !nonce_stream) begin
			if (start_enc_i) mode_enc <= 1'b1;
			else if (start_dec_i) mode_enc <= 1'b0;
		end
	end
    
    // -------------------------
    // Flatten 32-bit input to 128-bit for core
    // -------------------------
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            core_bdi <= '0;
            core_bdi_valid <= '0;
            core_bdi_type <= D_NULL;
            core_bdi_eot <= 1'b0;
            core_bdi_eoi <= 1'b0;
            core_key <= '0;
            core_nonce <= '0;
            core_key_valid <= 1'b0;
            ////////
			key_idx         <= '0;
			key_stream      <= 1'b0;
			nonce_idx       <= '0;
			nonce_stream    <= 1'b0;
        end else begin
             // defaults mỗi chu kỳ
			core_bdi_valid  <= '0;
			core_key_valid  <= 1'b0;
			core_bdi_type   <= D_NULL;
			core_bdi_eot    <= 1'b0;
			core_bdi_eoi    <= 1'b0;

			// Bắt đầu stream KEY khi có key_valid_i từ regs
			if (key_valid_i && !key_stream && !nonce_stream) begin
			  core_key   <= key_i;      // chụp đủ 128b
			  key_idx    <= 2'd0;
			  key_stream <= 1'b1;
			end

			// Stream từng word KEY 32b vào cổng .key
			if (key_stream) begin
			  core_key_valid <= 1'b1;
			  // nhích sang word kế tiếp mỗi chu kỳ (đơn giản hóa, có thể dùng key_ready)
			  key_idx    <= key_idx + 2'd1;
			  if (key_idx == 2'd3) key_stream <= 1'b0;
			end

			// Sau khi nhận start_enc/dec, stream NONCE 4x32 qua BDI (1 lần)
			if ((start_enc_i || start_dec_i) && !key_stream && !nonce_stream) begin
			  core_nonce   <= nonce_i;     // chụp đủ 128b nonce
			  nonce_idx    <= 2'd0;
			  nonce_stream <= 1'b1;
			end

			if (nonce_stream) begin
			  // đẩy 1 word nonce lên BDI mỗi chu kỳ
			  unique case (nonce_idx)
				2'd0: core_bdi <= core_nonce[31:0];
				2'd1: core_bdi <= core_nonce[63:32];
				2'd2: core_bdi <= core_nonce[95:64];
				default: core_bdi <= core_nonce[127:96];
			  endcase
			  //core_bdi_valid <= 4'hF;
			core_bdi_valid <= {CCW/8{1'b1}};	
			  core_bdi_type  <= D_NONCE;
			  core_bdi_eot   <= (nonce_idx == 2'd3);
			  core_bdi_eoi   <= (nonce_idx == 2'd3);

			  nonce_idx <= nonce_idx + 2'd1;
			  if (nonce_idx == 2'd3) nonce_stream <= 1'b0;
			end

			// Mỗi lần data_in_valid_i coi là 1 message 32-bit độc lập
			if (!key_stream && !nonce_stream && data_in_valid_i) begin
			  core_bdi       <= data_in_i;
			 // core_bdi_valid <= 4'hF;
				core_bdi_valid <= {CCW/8{1'b1}};
			  core_bdi_type  <= D_MSG;
			  core_bdi_eot   <= 1'b1;  // từ cuối
			  core_bdi_eoi   <= 1'b1;  // end-of-input
			end
		  end
		end
			
			// Chọn word KEY hiện tại (theo key_idx) nạp vào cổng .key
		wire [31:0] core_key_word =
		  (key_idx==2'd0) ? core_key[31:0]   :
		  (key_idx==2'd1) ? core_key[63:32]  :
		  (key_idx==2'd2) ? core_key[95:64]  :
							core_key[127:96];

    // -------------------------
    // Instantiate ASCON core
    // -------------------------
    ascon_core u_ascon_core (
        .clk         (clk_i),
        .rst         (~rst_ni),
        .key         (core_key_word),
        .key_valid   (core_key_valid),
        .key_ready   (),          // unused
        .bdi         (core_bdi),
        .bdi_valid   (core_bdi_valid),
        .bdi_ready   (),          // optional handshake
        .bdi_type    (core_bdi_type),
        .bdi_eot     (core_bdi_eot),
        .bdi_eoi     (core_bdi_eoi),
        .mode        (start_enc_i ? M_ENC : M_DEC),
        .bdo         (core_bdo[31:0]),
        .bdo_valid   (core_bdo_valid),
        .bdo_ready   (core_bdo_ready),
        .bdo_type    (core_bdo_type),
        .bdo_eot     (core_bdo_eot),
        .bdo_eoo     (1'b0),
        .auth        (core_auth),
        .auth_valid  (core_auth_valid),
        .done        (core_done)
    );

    // -------------------------
    // Map core output to register block
    // -------------------------
    assign data_out_o       = core_bdo; // send lower 32-bit word
    assign data_out_valid_o = core_bdo_valid;
    assign busy_o           = !core_done;
    assign auth_o           = core_auth;
    assign done_o           = core_done;

endmodule
