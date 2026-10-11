# Builds the cairo Port. Mix runs this (see mix.exs) with OUT set to the
# app's priv directory; `make` alone builds ./cairo_port.
OUT ?= cairo_port
PKGS = cairo freetype2
CFLAGS ?= -O2 -g -Wall -Wextra -Wno-unused-parameter
CFLAGS += $(shell pkg-config --cflags $(PKGS))
LDLIBS += $(shell pkg-config --libs $(PKGS)) -lm

$(OUT): cairo_port.c
	@mkdir -p $(dir $(OUT))
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)

clean:
	rm -f cairo_port

.PHONY: clean
