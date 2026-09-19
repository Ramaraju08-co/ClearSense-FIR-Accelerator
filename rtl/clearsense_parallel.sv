module clearsense_parallel #(
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

    localparam int RESET_COEFF_INT =
        (1 << FRAC_W) / TAPS;

    logic signed [COEFF_W-1:0]
        coeff_mem [0:TAPS-1];

    logic signed [DATA_W-1:0]
        history [0:TAPS-1];

    logic signed [ACC_W-1:0]
        acc_comb;

    integer i;
    integer k;

    /*
     * The parallel architecture can accept a sample whenever
     * the output register is free or the current output is
     * being consumed.
     */
    assign in_ready =
        ~out_valid | out_ready;


    /*
     * Parallel multiply-accumulate datapath.
     *
     * Tap 0 operates on the current input sample.
     * Remaining taps operate on stored sample history.
     */
    always_comb begin

        acc_comb = '0;

        acc_comb =
            acc_comb +
            ($signed(in_data) *
             $signed(coeff_mem[0]));

        for (k = 1; k < TAPS; k = k + 1) begin

            acc_comb =
                acc_comb +
                ($signed(history[k-1]) *
                 $signed(coeff_mem[k]));

        end
    end


    /*
     * Convert accumulated Q1.15 weighted result
     * back to the sample scale.
     *
     * Includes:
     *   - symmetric round-to-nearest
     *   - signed output saturation
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


            /*
             * Symmetric rounding.
             */
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
             * Maximum signed output:
             *  0111...111
             */
            max_out = '0;

            max_out[DATA_W-2:0] =
                {(DATA_W-1){1'b1}};


            /*
             * Minimum signed output:
             *  1000...000
             */
            min_out = '1;

            min_out[DATA_W-2:0] =
                {(DATA_W-1){1'b0}};


            /*
             * Saturation logic.
             */
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
     * Sequential state:
     *
     * - sample-history shift register
     * - coefficient storage
     * - output register
     */
    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            out_data  <= '0;
            out_valid <= 1'b0;

            /*
             * Reset loads a uniform moving-average
             * coefficient profile.
             */
            for (i = 0; i < TAPS; i = i + 1) begin

                history[i] <= '0;

                coeff_mem[i] <=
                    RESET_COEFF_INT;

            end

        end

        else begin

            /*
             * Runtime coefficient programming.
             *
             * If a coefficient write and input transfer
             * occur on the same clock edge, the sample
             * uses the previous coefficient value.
             */
            if (
                coeff_wr_en &&
                (coeff_wr_addr < TAPS)
            ) begin

                coeff_mem[coeff_wr_addr]
                    <= coeff_wr_data;

            end


            /*
             * Remove output after the receiver accepts it.
             */
            if (out_valid && out_ready)

                out_valid <= 1'b0;


            /*
             * Accept a new sensor sample.
             */
            if (in_valid && in_ready) begin

                /*
                 * Shift previous samples.
                 */
                for (
                    i = TAPS-1;
                    i > 0;
                    i = i - 1
                ) begin

                    history[i]
                        <= history[i-1];

                end


                history[0]
                    <= in_data;


                /*
                 * Store filtered result.
                 */
                out_data
                    <= round_and_saturate(
                        acc_comb
                    );


                out_valid
                    <= 1'b1;

            end

        end

    end

endmodule
