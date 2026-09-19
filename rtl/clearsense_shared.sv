module clearsense_shared #(
    parameter int DATA_W  = 16,
    parameter int COEFF_W = 16,
    parameter int FRAC_W  = 15,
    parameter int TAPS    = 16,
    parameter int ADDR_W  = (TAPS <= 1) ? 1 : $clog2(TAPS)
) (
    input  logic                         clk,
    input  logic                         rst_n,

    input  logic signed [DATA_W-1:0]     in_data,
    input  logic                         in_valid,
    output logic                         in_ready,

    output logic signed [DATA_W-1:0]     out_data,
    output logic                         out_valid,
    input  logic                         out_ready,

    input  logic                         coeff_wr_en,
    input  logic [ADDR_W-1:0]            coeff_wr_addr,
    input  logic signed [COEFF_W-1:0]    coeff_wr_data
);

    localparam int PROD_W =
        DATA_W + COEFF_W;

    localparam int GROWTH_W =
        (TAPS <= 1) ? 0 : $clog2(TAPS);

    localparam int ACC_W =
        PROD_W + GROWTH_W + 2;

    localparam int TAP_W =
        (TAPS <= 1) ? 1 : $clog2(TAPS);

    localparam int RESET_COEFF_INT =
        (1 << FRAC_W) / TAPS;


    logic signed [COEFF_W-1:0]
        coeff_mem [0:TAPS-1];

    logic signed [DATA_W-1:0]
        history [0:TAPS-1];

    /*
     * Snapshot of samples used during one
     * complete multiply-accumulate operation.
     */
    logic signed [DATA_W-1:0]
        sample_mem [0:TAPS-1];

    logic signed [ACC_W-1:0]
        accumulator;

    logic [TAP_W-1:0]
        tap_index;

    logic
        busy;

    logic signed [PROD_W-1:0]
        mult_result;

    logic signed [ACC_W-1:0]
        mult_extended;

    logic signed [ACC_W-1:0]
        final_sum;

    integer i;


    /*
     * A new sample can only be accepted when:
     *
     * 1. the MAC engine is idle
     * 2. no previous output is waiting
     */
    assign in_ready =
        (!busy) && (!out_valid);


    /*
     * Only one multiplier is used.
     */
    always_comb begin

        mult_result =
            $signed(sample_mem[tap_index]) *
            $signed(coeff_mem[tap_index]);

        mult_extended =
            {{(ACC_W-PROD_W){mult_result[PROD_W-1]}},
             mult_result};

        final_sum =
            accumulator + mult_extended;

    end


    /*
     * Symmetric rounding and saturation.
     */
    function automatic
        logic signed [DATA_W-1:0]
        round_and_saturate
        (
            input logic signed
            [ACC_W-1:0] value
        );

        logic signed [ACC_W:0]
            ext_value;

        logic signed [ACC_W:0]
            magnitude;

        logic signed [ACC_W:0]
            rounded;

        logic signed [ACC_W:0]
            half_lsb;

        logic signed [ACC_W:0]
            max_out;

        logic signed [ACC_W:0]
            min_out;

        begin

            ext_value =
                {value[ACC_W-1], value};

            half_lsb = '0;

            if (FRAC_W > 0)
                half_lsb =
                    ({{ACC_W{1'b0}}, 1'b1}
                     <<< (FRAC_W-1));


            if (FRAC_W == 0) begin

                rounded =
                    ext_value;

            end

            else if (ext_value >= 0) begin

                rounded =
                    (ext_value + half_lsb)
                    >>> FRAC_W;

            end

            else begin

                magnitude =
                    -ext_value;

                rounded =
                    -((magnitude + half_lsb)
                    >>> FRAC_W);

            end


            /*
             * Largest DATA_W-bit signed value.
             */
            max_out = '0;

            max_out[DATA_W-2:0] =
                {(DATA_W-1){1'b1}};


            /*
             * Smallest DATA_W-bit signed value.
             */
            min_out = '1;

            min_out[DATA_W-2:0] =
                {(DATA_W-1){1'b0}};


            if (rounded > max_out)

                round_and_saturate =
                    {1'b0,
                     {(DATA_W-1){1'b1}}};

            else if (rounded < min_out)

                round_and_saturate =
                    {1'b1,
                     {(DATA_W-1){1'b0}}};

            else

                round_and_saturate =
                    rounded[DATA_W-1:0];

        end

    endfunction


    /*
     * Sequential control for the shared
     * multiplier architecture.
     */
    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            accumulator <= '0;
            tap_index   <= '0;

            out_data    <= '0;
            out_valid   <= 1'b0;

            busy        <= 1'b0;


            /*
             * Reset coefficient memory to a
             * uniform moving-average filter.
             */
            for (i = 0; i < TAPS; i = i + 1) begin

                coeff_mem[i]
                    <= RESET_COEFF_INT;

                history[i]
                    <= '0;

                sample_mem[i]
                    <= '0;

            end

        end

        else begin

            /*
             * Output remains valid until the
             * downstream receiver accepts it.
             */
            if (out_valid && out_ready)

                out_valid <= 1'b0;


            /*
             * Coefficients can only be modified
             * when the MAC engine is idle and
             * there is no pending output.
             */
            if (
                coeff_wr_en &&
                !busy &&
                !out_valid &&
                (coeff_wr_addr < TAPS)
            ) begin

                coeff_mem[coeff_wr_addr]
                    <= coeff_wr_data;

            end


            /*
             * Accept a new sensor sample.
             */
            if (in_valid && in_ready) begin

                /*
                 * Capture complete sample window
                 * for the sequential MAC operation.
                 */
                sample_mem[0]
                    <= in_data;

                for (i = 1; i < TAPS; i = i + 1) begin

                    sample_mem[i]
                        <= history[i-1];

                end


                /*
                 * Update the main history.
                 */
                for (i = TAPS-1; i > 0; i = i - 1) begin

                    history[i]
                        <= history[i-1];

                end

                history[0]
                    <= in_data;


                /*
                 * Start MAC sequence.
                 */
                accumulator
                    <= '0;

                tap_index
                    <= '0;

                busy
                    <= 1'b1;

            end


            /*
             * Perform exactly one
             * multiplication per clock.
             */
            else if (busy) begin

                if (tap_index == TAPS-1) begin

                    /*
                     * Final tap.
                     */
                    out_data
                        <= round_and_saturate(
                            final_sum
                        );

                    out_valid
                        <= 1'b1;

                    accumulator
                        <= '0;

                    tap_index
                        <= '0;

                    busy
                        <= 1'b0;

                end

                else begin

                    accumulator
                        <= final_sum;

                    tap_index
                        <= tap_index + 1'b1;

                end

            end

        end

    end

endmodule
