# Builds the Level Zero NPU counters Port. Mix runs this (see mix.exs) with
# OUT set to the app's priv directory; `make` alone builds ./npu_port.
OUT ?= npu_port
PKGS = level-zero
CFLAGS ?= -O2 -g -Wall -Wextra -Wno-unused-parameter
CFLAGS += $(shell pkg-config --cflags $(PKGS))
LDLIBS += $(shell pkg-config --libs $(PKGS))

$(OUT): npu_port.c
	@mkdir -p $(dir $(OUT))
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)

clean:
	rm -f npu_port

.PHONY: clean
