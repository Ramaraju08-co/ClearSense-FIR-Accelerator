`timescale 1ns/1ps

module tb_clearsense #(
    parameter integer DATA_W     = 16,
    parameter integer COEFF_W    = 16,
    parameter integer FRAC_W     = 15,
    parameter integer TAPS       = 16,
    parameter integer USE_SHARED = 0
);

    localparam integer ADDR_W =
        (TAPS <= 1) ? 1 : $clog2(TAPS);

    localparam integer QUEUE_DEPTH = 4096;

    localparam logic signed [DATA_W-1:0] MAX_SAMPLE =
        {1'b0, {(DATA_W-1){1'b1}}};

    localparam logic signed [DATA_W-1:0] MIN_SAMPLE =
        {1'b1, {(DATA_W-1){1'b0}}};


    logic clk;
    logic rst_n;

    logic signed [DATA_W-1:0] in_data;
    logic                     in_valid;
    logic                     in_ready;

    logic signed [DATA_W-1:0] out_data;
    logic                     out_valid;
    logic                     out_ready;

    logic                     coeff_wr_en;
    logic [ADDR_W-1:0]        coeff_wr_addr;
    logic signed [COEFF_W-1:0] coeff_wr_data;


    /*
     * Reference-model state
     */
    longint signed model_history [0:TAPS-1];
    longint signed model_coeff   [0:TAPS-1];

    logic signed [DATA_W-1:0]
        expected_mem [0:QUEUE_DEPTH-1];

    integer q_head;
    integer q_tail;
    integer q_count;

    integer accepted_count;
    integer consumed_count;
    integer error_count;
    integer cycle_count;

    logic [31:0] sample_lfsr;
    logic [31:0] stall_lfsr;

    integer i;


    /*
     * Clock: 100 MHz
     */
    initial begin
        clk = 1'b0;

        forever #5 clk = ~clk;
    end


    /*
     * Select which ClearSense architecture
     * is being verified.
     */
    generate

        if (USE_SHARED == 0) begin : GEN_PARALLEL

            clearsense_parallel #(
                .DATA_W  (DATA_W),
                .COEFF_W (COEFF_W),
                .FRAC_W  (FRAC_W),
                .TAPS    (TAPS),
                .ADDR_W  (ADDR_W)
            ) dut (
                .clk           (clk),
                .rst_n         (rst_n),

                .in_data       (in_data),
                .in_valid      (in_valid),
                .in_ready      (in_ready),

                .out_data      (out_data),
                .out_valid     (out_valid),
                .out_ready     (out_ready),

                .coeff_wr_en   (coeff_wr_en),
                .coeff_wr_addr (coeff_wr_addr),
                .coeff_wr_data (coeff_wr_data)
            );

        end

        else begin : GEN_SHARED

            clearsense_shared #(
                .DATA_W  (DATA_W),
                .COEFF_W (COEFF_W),
                .FRAC_W  (FRAC_W),
                .TAPS    (TAPS),
                .ADDR_W  (ADDR_W)
            ) dut (
                .clk           (clk),
                .rst_n         (rst_n),

                .in_data       (in_data),
                .in_valid      (in_valid),
                .in_ready      (in_ready),

                .out_data      (out_data),
                .out_valid     (out_valid),
                .out_ready     (out_ready),

                .coeff_wr_en   (coeff_wr_en),
                .coeff_wr_addr (coeff_wr_addr),
                .coeff_wr_data (coeff_wr_data)
            );

        end

    endgenerate


    /*
     * Deterministic pseudo-random generator.
     */
    function automatic logic [31:0]
        next_lfsr(
            input logic [31:0] value
        );

        begin

            next_lfsr = {
                value[30:0],
                value[31] ^
                value[21] ^
                value[1]  ^
                value[0]
            };

        end

    endfunction


    /*
     * Independent reference FIR model.
     */
    function automatic
        logic signed [DATA_W-1:0]
        reference_filter(
            input logic signed [DATA_W-1:0] sample
        );

        longint signed acc;
        longint signed rounded;
        longint signed magnitude;

        longint signed half_lsb;
        longint signed max_value;
        longint signed min_value;

        integer k;

        begin

            acc = 0;

            /*
             * Current sample = tap 0
             */
            acc =
                $signed(sample) *
                model_coeff[0];

            /*
             * Previous samples
             */
            for (k = 1; k < TAPS; k = k + 1) begin

                acc =
                    acc +
                    model_history[k-1] *
                    model_coeff[k];

            end


            /*
             * Symmetric round-to-nearest.
             */
            if (FRAC_W == 0) begin

                rounded = acc;

            end

            else begin

                half_lsb =
                    64'sd1 << (FRAC_W-1);

                if (acc >= 0) begin

                    rounded =
                        (acc + half_lsb)
                        >>> FRAC_W;

                end

                else begin

                    magnitude = -acc;

                    rounded =
                        -((magnitude + half_lsb)
                        >>> FRAC_W);

                end

            end


            /*
             * Signed DATA_W output range.
             */
            max_value =
                (64'sd1 << (DATA_W-1)) - 1;

            min_value =
                -(64'sd1 << (DATA_W-1));


            /*
             * Saturation.
             */
            if (rounded > max_value)

                reference_filter =
                    MAX_SAMPLE;

            else if (rounded < min_value)

                reference_filter =
                    MIN_SAMPLE;

            else

                reference_filter =
                    rounded[DATA_W-1:0];

        end

    endfunction


    /*
     * Randomized but deterministic
     * downstream backpressure.
     */
    always @(negedge clk) begin

        if (!rst_n) begin

            stall_lfsr <= 32'h51A7_C0DE;
            out_ready  <= 1'b1;

        end

        else begin

            stall_lfsr <=
                next_lfsr(stall_lfsr);

            /*
             * Roughly 75% ready.
             */
            out_ready <=
                stall_lfsr[0] |
                stall_lfsr[3];

        end

    end


    /*
     * Self-checking scoreboard.
     */
    always @(posedge clk) begin

        logic signed [DATA_W-1:0]
            expected_value;

        integer m;

        if (!rst_n) begin

            q_head = 0;
            q_tail = 0;
            q_count = 0;

            accepted_count = 0;
            consumed_count = 0;
            error_count = 0;
            cycle_count = 0;


            for (m = 0; m < TAPS; m = m + 1) begin

                model_history[m] = 0;

                model_coeff[m] =
                    (64'sd1 << FRAC_W) /
                    TAPS;

            end

        end

        else begin

            cycle_count =
                cycle_count + 1;


            /*
             * Check a consumed DUT output.
             */
            if (out_valid && out_ready) begin

                if (q_count == 0) begin

                    $display(
                        "ERROR: unexpected DUT output at cycle %0d",
                        cycle_count
                    );

                    error_count =
                        error_count + 1;

                end

                else begin

                    if (
                        $signed(out_data) !==
                        $signed(expected_mem[q_head])
                    ) begin

                        $display(
                            "ERROR cycle=%0d expected=%0d got=%0d",
                            cycle_count,
                            $signed(expected_mem[q_head]),
                            $signed(out_data)
                        );

                        error_count =
                            error_count + 1;

                    end

                    q_head =
                        (q_head + 1) %
                        QUEUE_DEPTH;

                    q_count =
                        q_count - 1;

                    consumed_count =
                        consumed_count + 1;

                end

            end


            /*
             * Create expected result whenever
             * the DUT accepts a new input.
             */
            if (in_valid && in_ready) begin

                if (q_count >= QUEUE_DEPTH) begin

                    $fatal(
                        1,
                        "Expected-output queue overflow"
                    );

                end


                expected_value =
                    reference_filter(in_data);

                expected_mem[q_tail] =
                    expected_value;

                q_tail =
                    (q_tail + 1) %
                    QUEUE_DEPTH;

                q_count =
                    q_count + 1;

                accepted_count =
                    accepted_count + 1;


                /*
                 * Update reference history
                 * after calculating the output.
                 */
                for (
                    m = TAPS-1;
                    m > 0;
                    m = m - 1
                ) begin

                    model_history[m] =
                        model_history[m-1];

                end

                model_history[0] =
                    $signed(in_data);

            end


            /*
             * Update reference coefficients.
             *
             * Testbench only performs writes
             * while the DUT is idle.
             */
            if (coeff_wr_en) begin

                model_coeff[coeff_wr_addr] =
                    $signed(coeff_wr_data);

            end

        end

    end


    /*
     * Send one sensor sample using
     * the valid/ready protocol.
     */
    task automatic send_sample(
        input logic signed [DATA_W-1:0] sample
    );

        begin

            @(negedge clk);

            in_data  = sample;
            in_valid = 1'b1;


            @(posedge clk);

            while (!in_ready)
                @(posedge clk);


            @(negedge clk);

            in_valid = 1'b0;

        end

    endtask


    /*
     * Wait until all generated outputs
     * have been checked.
     */
    task automatic drain_outputs;

        begin

            while (
                (q_count != 0) ||
                out_valid
            )
                @(posedge clk);

            repeat (2)
                @(posedge clk);

        end

    endtask


    /*
     * Program one FIR coefficient.
     */
    task automatic write_coefficient(
        input integer address,
        input integer value
    );

        begin

            /*
             * Wait until architecture is idle.
             */
            while (
                !in_ready ||
                out_valid
            )
                @(negedge clk);


            coeff_wr_addr =
                address[ADDR_W-1:0];

            coeff_wr_data =
                value;

            coeff_wr_en =
                1'b1;


            @(posedge clk);
            @(negedge clk);


            coeff_wr_en =
                1'b0;

        end

    endtask


    /*
     * Main regression sequence.
     */
    initial begin

        integer n;
        integer coeff_value;

        logic signed [DATA_W-1:0]
            generated_sample;


        rst_n         = 1'b0;

        in_data       = '0;
        in_valid      = 1'b0;

        coeff_wr_en   = 1'b0;
        coeff_wr_addr = '0;
        coeff_wr_data = '0;

        out_ready     = 1'b1;

        sample_lfsr   = 32'h1ACE_B00C;
        stall_lfsr    = 32'h51A7_C0DE;


        /*
         * Reset
         */
        repeat (5)
            @(posedge clk);

        @(negedge clk);

        rst_n =
            1'b1;


        $display("");
        $display(
            "-----------------------------------------------"
        );
        $display(
            "ClearSense regression started"
        );
        $display(
            "Architecture : %s",
            USE_SHARED ? "SHARED" : "PARALLEL"
        );
        $display(
            "DATA_W       : %0d",
            DATA_W
        );
        $display(
            "TAPS         : %0d",
            TAPS
        );
        $display(
            "-----------------------------------------------"
        );


        /*
         * =================================================
         * PHASE 1
         * Default moving-average coefficients
         * 1536 samples
         * =================================================
         */
        for (n = 0; n < 1536; n = n + 1) begin

            sample_lfsr =
                next_lfsr(sample_lfsr);

            generated_sample =
                $signed(
                    sample_lfsr[DATA_W-1:0]
                );

            send_sample(
                generated_sample
            );

        end


        drain_outputs();


        /*
         * =================================================
         * PHASE 2
         * Near-unity pass-through profile
         * 256 samples
         * =================================================
         */

        /*
         * Tap 0 ≈ +1.0
         */
        coeff_value =
            (1 << FRAC_W) - 1;

        write_coefficient(
            0,
            coeff_value
        );


        /*
         * Remaining coefficients = 0
         */
        for (n = 1; n < TAPS; n = n + 1) begin

            write_coefficient(
                n,
                0
            );

        end


        for (n = 0; n < 256; n = n + 1) begin

            sample_lfsr =
                next_lfsr(sample_lfsr);

            generated_sample =
                $signed(
                    sample_lfsr[DATA_W-1:0]
                );

            send_sample(
                generated_sample
            );

        end


        drain_outputs();


        /*
         * =================================================
         * PHASE 3
         * Difference filter
         *
         * y[n] ≈ x[n] - x[n-1]
         *
         * Includes full-scale samples to exercise
         * saturation behavior.
         *
         * 256 samples
         * =================================================
         */

        write_coefficient(
            0,
            (1 << FRAC_W) - 1
        );

        write_coefficient(
            1,
            -(1 << FRAC_W)
        );


        for (n = 2; n < TAPS; n = n + 1) begin

            write_coefficient(
                n,
                0
            );

        end


        for (n = 0; n < 256; n = n + 1) begin

            case (n % 8)

                0:
                    generated_sample =
                        MAX_SAMPLE;

                1:
                    generated_sample =
                        MIN_SAMPLE;

                2:
                    generated_sample =
                        MAX_SAMPLE;

                3:
                    generated_sample =
                        MIN_SAMPLE;

                default: begin

                    sample_lfsr =
                        next_lfsr(
                            sample_lfsr
                        );

                    generated_sample =
                        $signed(
                            sample_lfsr[
                                DATA_W-1:0
                            ]
                        );

                end

            endcase


            send_sample(
                generated_sample
            );

        end


        drain_outputs();


        /*
         * Final report
         */
        $display("");
        $display(
            "==============================================="
        );
        $display(
            "ClearSense regression completed"
        );
        $display(
            "Architecture     : %s",
            USE_SHARED ? "SHARED" : "PARALLEL"
        );
        $display(
            "DATA_W           : %0d",
            DATA_W
        );
        $display(
            "TAPS             : %0d",
            TAPS
        );
        $display(
            "Accepted samples : %0d",
            accepted_count
        );
        $display(
            "Checked outputs  : %0d",
            consumed_count
        );
        $display(
            "Simulation cycles: %0d",
            cycle_count
        );
        $display(
            "Errors            : %0d",
            error_count
        );
        $display(
            "==============================================="
        );


        if (
            accepted_count != 2048
        ) begin

            $fatal(
                1,
                "Expected 2048 accepted samples"
            );

        end


        if (
            consumed_count !=
            accepted_count
        ) begin

            $fatal(
                1,
                "Input/output sample count mismatch"
            );

        end


        if (
            error_count == 0
        ) begin

            $display("");
            $display(
                "PASS: ClearSense configuration verified."
            );
            $display("");

        end

        else begin

            $fatal(
                1,
                "FAIL: %0d mismatches detected",
                error_count
            );

        end


        $finish;

    end


    /*
     * Safety timeout.
     */
    initial begin

        #50000000;

        $fatal(
            1,
            "Simulation timeout"
        );

    end

endmodule
