// pulp-platform apb_uart_sv (16550-compatible). Own library - see README.
// upstream carries no `timescale directive; the top-level filelist supplies
// one via rtl/third_party/timescale.f (D-22, and -timescale is once-only)
-makelib pulp_uart
  -sv
  rtl/third_party/pulp/apb_uart_sv/src/io_generic_fifo.sv
  rtl/third_party/pulp/apb_uart_sv/src/uart_rx.sv
  rtl/third_party/pulp/apb_uart_sv/src/uart_tx.sv
  rtl/third_party/pulp/apb_uart_sv/src/uart_interrupt.sv
  rtl/third_party/pulp/apb_uart_sv/src/apb_uart.sv
-endlib
