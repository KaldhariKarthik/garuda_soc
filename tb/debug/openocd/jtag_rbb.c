/* jtag_rbb.c -- OpenOCD remote_bitbang server for the simulation (Track A plan 6A.5 G7).
 * Flow glue only (like the Spike bridge in tools/cosim): it moves JTAG pin values between
 * OpenOCD's TCP socket and the SystemVerilog bench (tb/debug/openocd/tb_debug_ocd.sv), which
 * holds all the checking. Protocol (OpenOCD doc/manual remote_bitbang): '0'..'7' set
 * {tck, tms, tdi}; 'R' read tdo -> '0'/'1'; 'r' 's' 't' 'u' reset lines; 'B' 'b' blink; 'Q' quit. */
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#ifdef __cplusplus
extern "C" {          /* Verilator compiles this file as C++: keep the DPI names unmangled */
#endif
static int lfd = -1, cfd = -1;

int rbb_open(int port)
{
    struct sockaddr_in a;
    int one = 1;
    lfd = socket(AF_INET, SOCK_STREAM, 0);
    if (lfd < 0) return -1;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_addr.s_addr = htonl(INADDR_LOOPBACK); a.sin_port = htons(port);
    if (bind(lfd, (struct sockaddr *)&a, sizeof a) < 0 || listen(lfd, 1) < 0) return -1;
    fprintf(stderr, "[rbb] listening on 127.0.0.1:%d\n", port);
    cfd = accept(lfd, 0, 0);                         /* blocks until OpenOCD connects */
    if (cfd < 0) return -1;
    setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    fprintf(stderr, "[rbb] OpenOCD connected\n");
    return 0;
}

/* One command. Returns: 0..7 = new {tck,tms,tdi}; 8 = a tdo read was answered;
 * 9 = nothing to do (reset/blink); -1 = quit / connection closed. */
int rbb_step(int tdo)
{
    unsigned char c;
    ssize_t n;
    if (cfd < 0) return -1;
    n = read(cfd, &c, 1);
    if (n <= 0) return -1;
    if (c >= '0' && c <= '7') return c - '0';
    if (c == 'R') { char r = tdo ? '1' : '0'; if (write(cfd, &r, 1) != 1) return -1; return 8; }
    if (c == 'Q') return -1;
    return 9;
}
#ifdef __cplusplus
}
#endif
