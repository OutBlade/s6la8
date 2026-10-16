// Development key: authentication is computed but not enforced, so builds
// from this repository work on any board.  Production builds use auth_key.vh
// from tools/provision.py keyfile (never committed) and define S6LA8_PRODUCTION.
localparam [127:0] AUTH_KEY = 128'h0;
localparam AUTH_REQUIRED = 0;
