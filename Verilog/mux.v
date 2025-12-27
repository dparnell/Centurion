module MUX(
    input wire bit_clock, // 27Mhz clock
    input wire cpu_clock,
    input uart_rx,
    output uart_tx,    
    input wire selected,
    input wire [4:0] address, 
    input wire write_en, 
    input wire [7:0] data_in,
    output wire [7:0] data_out,
    output wire int_reqn,
    output wire [3:0] irq_number
);

// common stuff - default to 9600 7E1

reg [15:0] divider = 2812; // 9600
reg parity = 1;
reg parity_enabled = 1;
reg [3:0] data_bits = 7;
reg stop_bits = 0;

reg interrupts_enabled = 0;
reg [3:0] interupt_level = 0;

// CPU interface
always @(posedge cpu_clock) begin
    if (selected) begin
        if(write_en) begin
            case(address) 
                0: begin  // control register
                    parity = data_in[0];
                    data_bits = 5 + data_in[3:1];
                    parity_enabled = data_in[4];
                    stop_bits = data_in[5];

                    case (data_in[7:5])
                        0: divider = 27_000_000 / 75;
                        1: divider = 27_000_000 / 300;
                        2: divider = 27_000_000 / 1200;
                        3: divider = 27_000_000 / 2400;
                        4: divider = 27_000_000 / 4800;
                        5: divider = 27_000_000 / 9600;
                        6: divider = 27_000_000 / 19200;
                        7: divider = 27_000_000 / 38400;
                    endcase
                end

                1: begin // data register
                    output_data = data_in;
                end

                10: begin // interrupt level
                    interrupt_level = data_in[3:0];
                end

                13: interrupts_enabled = 0;
                14: interrupts_enabled = 1;
                15: begin
                    divider = 2812;
                    parity = 1;
                    parity_enabled = 1;
                    data_bits = 7;
                    stop_bits = 0;
                end
            endcase
        end else begin
            case(address)
                0: data_out = { 6'b000000, txState == TX_STATE_IDLE ? 1 : 0, byteReady}; // status register
                1: data_out = data_in;
            endcase
        end
    end
end

// rx

reg [3:0] rxState = 0;
reg [12:0] rxCounter = 0;
reg [7:0] dataIn = 0;
reg [2:0] rxBitNumber = 0;
reg byteReady = 0;

localparam RX_STATE_IDLE = 0;
localparam RX_STATE_START_BIT = 1;
localparam RX_STATE_READ_WAIT = 2;
localparam RX_STATE_READ = 3;
localparam RX_STATE_STOP_BIT = 5;

always @(posedge clk) begin
    case (rxState)
        RX_STATE_IDLE: begin
            if (uart_rx == 0) begin
                rxState <= RX_STATE_START_BIT;
                rxCounter <= 1;
                rxBitNumber <= 0;
                byteReady <= 0;
            end
        end 
        RX_STATE_START_BIT: begin
            if (rxCounter == delay[15:1]) begin
                rxState <= RX_STATE_READ_WAIT;
                rxCounter <= 1;
            end else 
                rxCounter <= rxCounter + 1;
        end
        RX_STATE_READ_WAIT: begin
            rxCounter <= rxCounter + 1;
            if ((rxCounter + 1) == DELAY_FRAMES) begin
                rxState <= RX_STATE_READ;
            end
        end
        RX_STATE_READ: begin
            rxCounter <= 1;
            dataIn <= {uart_rx, dataIn[7:1]};
            rxBitNumber <= rxBitNumber + 1;
            if (rxBitNumber == data_bits)
                rxState <= RX_STATE_STOP_BIT;
            else
                rxState <= RX_STATE_READ_WAIT;
        end
        RX_STATE_STOP_BIT: begin
            rxCounter <= rxCounter + 1;
            if ((rxCounter + 1) == DELAY_FRAMES) begin
                rxState <= RX_STATE_IDLE;
                rxCounter <= 0;
                byteReady <= 1;

                if (int_enabled) begin
                    irq_number = interrupt_level;
                    int_reqn = 0;
                end
            end
        end
    endcase
end



// tx

localparam TX_STATE_IDLE = 0;
localparam TX_STATE_START_BIT = 1;
localparam TX_STATE_WRITE = 2;
localparam TX_STATE_PARITY_BIT = 3;
localparam TX_STATE_STOP_BIT = 4;
localparam TX_STATE_STOP_BIT_2 = 5;

reg [7:0] output_data;
reg [3:0] txState = TX_STATE_IDLE;
reg [24:0] txCounter = 0;
reg txPinRegister = 1;
reg [2:0] txBitNumber = 0;

assign uart_tx = txPinRegister;
wire parity_bit;
assign parity_bit = parity_enabled ? ^UI[7:0] : 1'b1;

always @(posedge bit_clock) begin
    case (txState)
        TX_STATE_IDLE: begin
            txCounter <= 0;
            txByteCounter <= 0;
            txPinRegister <= 1;
        end 
        TX_STATE_START_BIT: begin
            txPinRegister <= 0;
            txCounter <= txCounter + 1;
            if (txCounter == divider) begin
                txState <= TX_STATE_WRITE;
                txBitNumber <= 0;
                txCounter <= 0;
            end 
                
        end
        TX_STATE_WRITE: begin
            txPinRegister <= output_data[txBitNumber];
            txCounter <= txCounter + 1;
            if (txCounter == divider) begin
                if (txBitNumber == data_bits) begin
                    if (parity_enabled) begin
                        txState <= TX_STATE_PARITY_BIT;
                    end else begin
                        txState <= TX_STATE_STOP_BIT;
                    end
                end else begin
                    txState <= TX_STATE_WRITE;
                    txBitNumber <= txBitNumber + 1;
                end
                txCounter <= 0;
            end 
        end
        TX_STATE_PARITY_BIT: begin
            txPinRegister <= parity_bit;
            txCounter <= txCounter + 1;
            if (txCounter == divider) begin
                txState <= TX_STATE_STOP_BIT;
                txCounter = 0;
            end            
        end        
        TX_STATE_STOP_BIT: begin
            txPinRegister <= 1;
            txCounter <= txCounter + 1;
            if (txCounter == divider) begin
                if (stop_bits) begin
                    txState <= TX_STATE_STOP_BIT_2;
                end else begin
                    txState <= TX_STATE_IDLE;
                end
                txCounter = 0;
            end            
        end
        TX_STATE_STOP_BIT_2: begin
            txPinRegister <= 1;
            txCounter <= txCounter + 1;
            if (txCounter == divider) begin
                txState <= TX_STATE_IDLE;
                txCounter = 0;
            end            
        end
    endcase      
end

endmodule