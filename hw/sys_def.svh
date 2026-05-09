//////////////////////////////////////////////////////////////////////////////////
// Engineers: Jayden Lee-Sin, Carlos Espinoza & Derrick Bassey (DAB2266)
// Create Date: 04/07/2026
// Project Name: Virtualized High Frequence Trading (HFT) Simulator
// Description:
//      This is a simple file to define parameters and structs that will be used 
//      across the various modules in this project. 
//
// Revision: 05/08/2026
//////////////////////////////////////////////////////////////////////////////////

`ifndef __SYS_DEFS_SVH__
`define __SYS_DEFS_SVH__

// Time scale
`timescale 1ns/100ps

// Word width
`define WORD_WIDTH 32

// Order Dispatch Parameters
`define SYM_NUM 8       // Number of symbols 
`define FIFO_SZ 1660  // 

// Structs 
/*
* Main Order Struct
*/
typedef struct packed {
    logic        type_;     // Ask (0) or Bid (1)
    logic [15:0] price;     // unsigned int in [0, 65,536]
    logic [15:0] quantity;  // unsigned int in [0, 65,536]
    logic [20:0] symbol;    // 3 ASCII uppercase char (7-bit each)
    logic [31:0] timestamp; // unsigned int in [0, 4,294,967,296]
} ORDER;

/*
* The orders stored in the dispatch:
*  - This is was is written to the input FIFOs
*  - This is was is passed from the Dipatcher to the engines.  
*/
typedef struct packed {
    logic        type_;     // Ask (0) or Bid (1)
    logic [15:0] price;     // unsigned int in [0, 65,536]
    logic [14:0] quantity;  // unsigned int in [0, 65,536]

} DISPATCH_ORDER;

typedef enum logic [1:0] {
  IDLE      = 2'd0,     // Doing nothing
  WRITE     = 2'd1,     // Waiting for harness to finish writing
  DISPATCH  = 2'd2,     // Dispatching orders
  DONE      = 2'd3      // Done dispatching
} DISPATCH_STATE;

`endif // __SYS_DEFS_SVH__
