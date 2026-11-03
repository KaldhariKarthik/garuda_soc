/* G0 item 0.3: bare-metal hello-world for GARUDA (RV32IM). It writes a word
 * to DSRAM and returns from main; crt0 and the link script are the project's. */
volatile unsigned int result;
int main(void) { result = 0x48454C4F; /* "HELO" */ return 0; }
