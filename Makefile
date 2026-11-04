

CONTINENTS='Europe', 'Asia','Africa'
REGIONS='ES', 'IT', 'UA', 'RU'
PRECISION=10m
PRECISIONREG=10m

.PHONY: all setup start-server download sources fix-crimea data normalize

# update data and README preview (map.png)
all: data
	$(MAKE) map.png

setup:
	# npm install -g mapshaper


start-server:
	python3 -m http.server 8000

download:
	if [ ! -f ne_$(PRECISION)_admin_0_countries.zip ]; then curl -L -o ne_$(PRECISION)_admin_0_countries.zip https://naciscdn.org/naturalearth/$(PRECISION)/cultural/ne_$(PRECISION)_admin_0_countries.zip; fi
	if [ ! -f ne_$(PRECISIONREG)_admin_1_states_provinces.zip ]; then curl -L -o ne_$(PRECISIONREG)_admin_1_states_provinces.zip https://naciscdn.org/naturalearth/$(PRECISIONREG)/cultural/ne_$(PRECISIONREG)_admin_1_states_provinces.zip; fi

sources: download
	rm -f countries.geojson states.geojson

	ogr2ogr -f GeoJSON -makevalid \
		-nln merged \
	  -sql "SELECT \
	    'country' as level, \
	    NAME as name, \
	    ISO_A2_EH as iso, \
	    CONTINENT as parent \
	  FROM ne_$(PRECISION)_admin_0_countries \
	  WHERE CONTINENT IN (${CONTINENTS}) \
	    AND TYPE != 'Dependency'" \
	  countries.geojson \
	  /vsizip/ne_$(PRECISION)_admin_0_countries.zip

	ogr2ogr -f GeoJSON -makevalid \
	  -dialect SQLite \
		-nln states \
	  -sql "SELECT \
			'region' as level, \
	    name_en as name, \
	    REPLACE(code_hasc, '.', '-') as iso, \
	    CASE WHEN code_hasc LIKE 'UA.%' THEN 'UA' ELSE ISO_A2 END as parent, \
	    geometry \
	  FROM ne_$(PRECISIONREG)_admin_1_states_provinces \
	  WHERE ISO_A2 IN (${REGIONS})" \
	  states.geojson \
	  /vsizip/ne_$(PRECISIONREG)_admin_1_states_provinces.zip




fix-crimea: sources
	rm -rf tmp
	mkdir -p tmp
	rm -f ua_fixed.geojson ru_fixed.geojson

	# countries + regions in one layer, so they can be combined in one SQL query
	cp countries.geojson tmp/merged.geojson
	ogr2ogr -f GeoJSON -append -nln merged tmp/merged.geojson states.geojson

	# Ukraine = Ukraine + Crimea (UA-KR) + Sevastopol (UA-SC)
	ogr2ogr -f GeoJSON -makevalid \
	  -dialect SQLite \
	  -nln ua \
	  -sql "SELECT \
	    'country' as level, \
	    'Ukraine' as name, \
	    'UA' as iso, \
	    'Europe' as parent, \
	    ST_Union(geometry) as geometry \
	  FROM merged \
	  WHERE (level = 'country' AND iso = 'UA') \
	    OR iso IN ('UA-KR', 'UA-SC')" \
	  ua_fixed.geojson \
	  tmp/merged.geojson

	# Russia = Russia - Crimea (UA-KR) - Sevastopol (UA-SC)
	ogr2ogr -f GeoJSON -makevalid \
	  -dialect SQLite \
	  -nln ru \
	  -sql "SELECT \
	    'country' as level, \
	    'Russia' as name, \
	    'RU' as iso, \
	    'Europe' as parent, \
	    ST_Difference( \
	      geometry, \
	      (SELECT ST_Union(geometry) FROM merged WHERE iso IN ('UA-KR', 'UA-SC')) \
	    ) as geometry \
	  FROM merged \
	  WHERE level = 'country' AND iso = 'RU'" \
	  ru_fixed.geojson \
	  tmp/merged.geojson

data: fix-crimea
	rm -f map.geojson

	# cp countries_fixed.geojson map.geojson
	cp countries.geojson map.geojson
	#ogr2ogr -f GeoJSON map.geojson others.geojson -nln merged #cp others.geojson map.geojson
	
	ogr2ogr -f GeoJSON \
	  -makevalid \
	  -append \
	  -nln merged \
	  -dialect SQLite \
	  -sql "SELECT \
	    level as level, \
	    MIN(name) as name, \
	    iso, \
	    parent, \
	    ST_Union(geometry) as geometry \
	  FROM states \
	  GROUP BY iso, parent" \
	  map.geojson \
	  states.geojson


normalize: $(FILE).geojson
	jq -S -c "\
	  .features |= map( \
	    .properties |= (to_entries | sort_by(.key) | from_entries) \
	  ) \
	" $(FILE).geojson | sed 's/\("type":"Feature"}\)/\1\n/g'| sed 's/\({"geometry"\)/\n\1/' > $(FILE).norm.geojson
  


# Render map.png (README preview) from index.htm in headless Firefox
#   make map.png [MAP_SIZE=1081] [MAP_SCALE=2] [FIREFOX=/usr/bin/firefox] [MAP_PORT=8765]
MAP_SIZE ?= 1081
MAP_SCALE ?= 2
MAP_PORT ?= 8765
FIREFOX ?= /usr/bin/firefox
MAP_DEPS = index.htm lib/map.js styles.css pressmint.css pressmint.js logo.png map.geojson ua_fixed.geojson ru_fixed.geojson

map.png: $(MAP_DEPS) render-map.mjs
	test -d node_modules/puppeteer-core || npm install
	python3 -m http.server $(MAP_PORT) --bind 127.0.0.1 >/dev/null 2>&1 & pid=$$!; \
	  sleep 1; \
	  node render-map.mjs http://127.0.0.1:$(MAP_PORT)/index.htm $@.tmp $(MAP_SIZE) $(MAP_SCALE) $(FIREFOX); \
	  rc=$$?; kill $$pid; \
	  [ $$rc -eq 0 ] && mv $@.tmp $@ || { rm -f $@.tmp; exit 1; }


# Visual check of the Crimea/Sevastopol patch: before vs. after + highlighted changes
#   make viz-patch [VIZ_BASE=<git rev with old data>] [VIZ_BBOX=xmin,ymin,xmax,ymax]
VIZ_BASE ?= 1b3201c
VIZ_BBOX ?= 29.5,43.8,40.0,47.6
VIZ_DIR = viz-patch
VIZ_STYLE_RU = -style target=ru fill='\#9CB3C5' stroke='\#ffffff' stroke-width=1
VIZ_STYLE_UA = -style target=ua fill='\#C7D987' stroke='\#ffffff' stroke-width=1
VIZ_STYLE_FRAME = -style target=frame fill=none stroke='\#052d4d' stroke-width=1
VIZ_STYLE_CITY = -style target=cities r=3 fill='\#052d4d' label-text='this.properties.name' font-size=13 dx=5 dy=-5

.PHONY: viz-patch
viz-patch:
	rm -rf $(VIZ_DIR)
	mkdir -p $(VIZ_DIR)/before $(VIZ_DIR)/after
	git show $(VIZ_BASE):ua_fixed.geojson > $(VIZ_DIR)/before/ua.full.geojson
	git show $(VIZ_BASE):ru.geojson > $(VIZ_DIR)/before/ru.full.geojson
	cp ua_fixed.geojson $(VIZ_DIR)/after/ua.full.geojson
	cp ru_fixed.geojson $(VIZ_DIR)/after/ru.full.geojson
	jq -n '[["Sevastopol",33.52,44.60],["Simferopol",34.10,44.95],["Kerch",36.47,45.36],["Kherson",32.62,46.64],["Krasnodar",38.98,45.04]] | {type:"FeatureCollection",features:map({type:"Feature",properties:{name:.[0]},geometry:{type:"Point",coordinates:.[1:]}})}' > $(VIZ_DIR)/cities.geojson

	# clip every layer separately (mapshaper -erase fails silently on the antimeridian-crossing RU polygon)
	for s in before after; do for c in ua ru; do \
	  mapshaper -quiet -i $(VIZ_DIR)/$$s/$$c.full.geojson -clip bbox=$(VIZ_BBOX) -o $(VIZ_DIR)/$$s/$$c.geojson; \
	done; done

	# changes: each difference in its own run
	mapshaper -quiet -i $(VIZ_DIR)/after/ua.geojson -erase $(VIZ_DIR)/before/ua.geojson -o $(VIZ_DIR)/ua_gained.geojson
	mapshaper -quiet -i $(VIZ_DIR)/before/ua.geojson -erase $(VIZ_DIR)/after/ua.geojson -o $(VIZ_DIR)/ua_lost.geojson
	mapshaper -quiet -i $(VIZ_DIR)/before/ru.geojson -erase $(VIZ_DIR)/after/ru.geojson -o $(VIZ_DIR)/ru_lost.geojson
	mapshaper -quiet -i $(VIZ_DIR)/after/ru.geojson -erase $(VIZ_DIR)/before/ru.geojson -o $(VIZ_DIR)/ru_gained.geojson
	# visible owner in the old map (UA drawn on top of RU): areas shown as RU before, UA now
	mapshaper -quiet -i $(VIZ_DIR)/before/ru.geojson -erase $(VIZ_DIR)/before/ua.geojson \
	  -clip $(VIZ_DIR)/after/ua.geojson -o $(VIZ_DIR)/shown_ru_now_ua.geojson

	# before / after: RU drawn below UA (same order as index.htm)
	for s in before after; do \
	  mapshaper -quiet \
	    -i $(VIZ_DIR)/$$s/ru.geojson $(VIZ_DIR)/$$s/ua.geojson $(VIZ_DIR)/cities.geojson combine-files \
	    -rename-layers ru,ua,cities \
	    -rectangle bbox=$(VIZ_BBOX) target=cities + name=frame \
	    $(VIZ_STYLE_RU) $(VIZ_STYLE_UA) $(VIZ_STYLE_FRAME) $(VIZ_STYLE_CITY) \
	    -proj merc target=* \
	    -o $(VIZ_DIR)/$$s.svg target=ru,ua,frame,cities fit-extent=frame width=1200; \
	done

	# diff: after state + red = added to UA, dashed blue = removed from RU, purple = removed from UA
	mapshaper -quiet \
	  -i $(VIZ_DIR)/after/ru.geojson $(VIZ_DIR)/after/ua.geojson \
	     $(VIZ_DIR)/ua_gained.geojson $(VIZ_DIR)/ua_lost.geojson $(VIZ_DIR)/ru_lost.geojson \
	     $(VIZ_DIR)/cities.geojson combine-files \
	  -rename-layers ru,ua,ua_gained,ua_lost,ru_lost,cities \
	  -rectangle bbox=$(VIZ_BBOX) target=cities + name=frame \
	  $(VIZ_STYLE_RU) $(VIZ_STYLE_UA) $(VIZ_STYLE_FRAME) $(VIZ_STYLE_CITY) \
	  -style target=ua_gained fill='#E4572E' fill-opacity=0.75 stroke='#a3290f' stroke-width=1 \
	  -style target=ua_lost fill='#8e44ad' fill-opacity=0.75 stroke='#5b2370' stroke-width=1 \
	  -style target=ru_lost fill=none stroke='#1f4e9c' stroke-width=2 stroke-dasharray='6 3' \
	  -proj merc target=* \
	  -o $(VIZ_DIR)/diff.svg target=ru,ua,ua_gained,ua_lost,ru_lost,frame,cities fit-extent=frame width=1200

	for s in before after diff; do \
	  inkscape $(VIZ_DIR)/$$s.svg --export-type=png --export-filename=$(VIZ_DIR)/$$s.png \
	    --export-background=white --export-width=1200 2>/dev/null; \
	done
	montage -font DejaVu-Sans -pointsize 22 \
	  -label 'before ($(VIZ_BASE))' $(VIZ_DIR)/before.png \
	  -label 'after (current)' $(VIZ_DIR)/after.png \
	  -label 'red = added to UA, purple = removed from UA, dashed blue = removed from RU' $(VIZ_DIR)/diff.png \
	  -tile 3x1 -geometry +15+15 -background white $(VIZ_DIR)/compare.png

	# areas (ellipsoidal) of the changes; mapshaper's this.area is not reliable here
	@for f in ua_gained ua_lost ru_gained ru_lost shown_ru_now_ua; do \
	  a=$$(ogrinfo -q -dialect SQLite -sql "SELECT ROUND(SUM(ST_Area(MakeValid(geometry), 1))/1e6) AS km2 FROM \"$$f\"" \
	    $(VIZ_DIR)/$$f.geojson 2>/dev/null | sed -n 's/.*km2 (Real) = //p'); \
	  printf '%-16s %8s km2\n' $$f "$${a:-0}"; \
	done | tee $(VIZ_DIR)/summary.txt
	@echo "Output in $(VIZ_DIR)/"
