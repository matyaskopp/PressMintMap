# MintMap make targets for projects - include from the project Makefile:
#
#   MAP_ROOT = ..                    # directory served to the browser (must contain the page and the library)
#   MAP_PAGE = pressmint/index.htm   # page relative to MAP_ROOT
#   include ../lib/map.mk
#
#   make map.png [MAP_SIZE=1081] [MAP_SCALE=2] [FIREFOX=/usr/bin/firefox] [MAP_PORT=8765]
#   make serve   (http://localhost:8000/$(MAP_PAGE))

MINTMAP_LIB := $(dir $(lastword $(MAKEFILE_LIST)))
MINTMAP := $(MINTMAP_LIB)..

MAP_ROOT ?= .
MAP_PAGE ?= index.htm
MAP_PNG ?= map.png
MAP_SIZE ?= 1081
MAP_SCALE ?= 2
MAP_PORT ?= 8765
FIREFOX ?= /usr/bin/firefox
# project files + library + data
MAP_DEPS ?= $(filter-out $(MAP_PNG),$(wildcard *.htm *.html *.js *.css *.png *.svg *.json *.topojson)) \
  $(MINTMAP_LIB)map.js $(MINTMAP_LIB)styles.css $(MINTMAP_LIB)render-map.mjs \
  $(wildcard $(MINTMAP)/data/*.topojson)

.PHONY: serve

serve:
	@echo "http://localhost:8000/$(MAP_PAGE)"
	python3 -m http.server 8000 --directory $(MAP_ROOT)

# render the page in headless Firefox (same output as the "PNG" button)
$(MAP_PNG): $(MAP_DEPS)
	test -d $(MINTMAP)/node_modules/puppeteer-core || npm install --prefix $(MINTMAP)
	python3 -m http.server $(MAP_PORT) --bind 127.0.0.1 --directory $(MAP_ROOT) >/dev/null 2>&1 & pid=$$!; \
	  sleep 1; \
	  node $(MINTMAP_LIB)render-map.mjs http://127.0.0.1:$(MAP_PORT)/$(MAP_PAGE) $@.tmp $(MAP_SIZE) $(MAP_SCALE) $(FIREFOX); \
	  rc=$$?; kill $$pid; \
	  [ $$rc -eq 0 ] && mv $@.tmp $@ || { rm -f $@.tmp; exit 1; }
