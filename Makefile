# MintMap library maintenance: prebuilt map data + PressMint example
#
#   make all        - rebuild data/europe.topojson and the PressMint map (pressmint/map.png)
#   make data       - rebuild data/europe.topojson from Natural Earth
#   make viz-patch  - check of the Crimea/Sevastopol patch (before/after images)
#
# projects using the library: see lib/map.mk

# countries in data (Natural Earth CONTINENT)
CONTINENTS = 'Europe', 'Asia', 'Africa'
# countries of these continents are included with regions (admin-1), e.g. "Europe", "Asia"
REGION_CONTINENTS = "Europe"
PRECISION = 10m
PRECISIONREG = 10m
# simplification (minimal distance between points in meters) and topojson quantization
SIMPLIFY = 1000
QUANTIZATION = 100000

BUILD = build
NE0 = ne_$(PRECISION)_admin_0_countries
NE1 = ne_$(PRECISIONREG)_admin_1_states_provinces
DATA = data/europe.topojson

.PHONY: all data download clean start-server

# never keep half-written targets
.DELETE_ON_ERROR:

all: data
	$(MAKE) -C pressmint map.png

data: $(DATA)

start-server:
	python3 -m http.server 8000

download: $(NE0).zip $(NE1).zip

$(NE0).zip $(NE1).zip:
	curl -L -o $@ https://naciscdn.org/naturalearth/$(PRECISION)/cultural/$@

clean:
	rm -rf $(BUILD)

$(BUILD)/countries.geojson: $(NE0).zip
	mkdir -p $(BUILD)
	rm -f $@
	ogr2ogr -f GeoJSON -makevalid \
	  -nln countries \
	  -sql "SELECT \
	    'country' as level, \
	    NAME as name, \
	    ISO_A2_EH as iso, \
	    CONTINENT as parent \
	  FROM $(NE0) \
	  WHERE CONTINENT IN ($(CONTINENTS)) \
	    AND TYPE != 'Dependency'" \
	  $@ /vsizip/$(NE0).zip

# regions of all countries in REGION_CONTINENTS, grouped by code (e.g. provinces -> ES-GA)
# Crimea and Sevastopol are labelled RU in Natural Earth -> assigned to UA
$(BUILD)/states.geojson: $(BUILD)/countries.geojson $(NE1).zip
	rm -f $@ $(BUILD)/states.all.geojson
	iso=$$(jq -r '[.features[].properties | select(.parent | IN($(REGION_CONTINENTS))) | "'"'"'" + .iso + "'"'"'"] | join(",")' $<); \
	ogr2ogr -f GeoJSON -makevalid \
	  -dialect SQLite \
	  -nln states \
	  -sql "SELECT \
	    'region' as level, \
	    name_en as name, \
	    REPLACE(code_hasc, '.', '-') as iso, \
	    CASE WHEN code_hasc LIKE 'UA.%' THEN 'UA' ELSE ISO_A2 END as parent, \
	    geometry \
	  FROM $(NE1) \
	  WHERE ISO_A2 IN ($$iso) AND code_hasc IS NOT NULL" \
	  $(BUILD)/states.all.geojson /vsizip/$(NE1).zip
	ogr2ogr -f GeoJSON -makevalid \
	  -dialect SQLite \
	  -nln states \
	  -sql "SELECT \
	    level as level, \
	    MIN(name) as name, \
	    iso, \
	    parent, \
	    ST_Union(geometry) as geometry \
	  FROM states \
	  GROUP BY iso, parent" \
	  $@ $(BUILD)/states.all.geojson

# Ukraine = Ukraine + Crimea (UA-KR) + Sevastopol (UA-SC), Russia = Russia - Crimea - Sevastopol
$(BUILD)/ua_fixed.geojson $(BUILD)/ru_fixed.geojson &: $(BUILD)/countries.geojson $(BUILD)/states.geojson
	rm -f $(BUILD)/merged.geojson $(BUILD)/ua_fixed.geojson $(BUILD)/ru_fixed.geojson
	# countries + regions in one layer, so they can be combined in one SQL query
	jq -s '{type: "FeatureCollection", name: "merged", features: map(.features[])}' \
	  $(BUILD)/countries.geojson $(BUILD)/states.geojson > $(BUILD)/merged.geojson
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
	  $(BUILD)/ua_fixed.geojson $(BUILD)/merged.geojson
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
	  $(BUILD)/ru_fixed.geojson $(BUILD)/merged.geojson

# all countries (UA/RU patched) + regions, simplified, as topojson
$(DATA): $(BUILD)/countries.geojson $(BUILD)/states.geojson $(BUILD)/ua_fixed.geojson $(BUILD)/ru_fixed.geojson
	mkdir -p $(dir $@)
	rm -f $(BUILD)/map.geojson
	jq -s '{type: "FeatureCollection", name: "map", features: ((.[0].features | map(select(.properties.iso | IN("UA", "RU") | not))) + (.[1:] | map(.features[])))}' \
	  $(BUILD)/countries.geojson $(BUILD)/ua_fixed.geojson $(BUILD)/ru_fixed.geojson $(BUILD)/states.geojson \
	  > $(BUILD)/map.geojson
	npx --no-install mapshaper -i $(BUILD)/map.geojson name=map \
	  -simplify interval=$(SIMPLIFY) keep-shapes \
	  -o format=topojson quantization=$(QUANTIZATION) $@
	@ls -la $@


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
viz-patch: $(BUILD)/ua_fixed.geojson
	rm -rf $(VIZ_DIR)
	mkdir -p $(VIZ_DIR)/before $(VIZ_DIR)/after
	git show $(VIZ_BASE):ua_fixed.geojson > $(VIZ_DIR)/before/ua.full.geojson
	git show $(VIZ_BASE):ru.geojson > $(VIZ_DIR)/before/ru.full.geojson
	cp $(BUILD)/ua_fixed.geojson $(VIZ_DIR)/after/ua.full.geojson
	cp $(BUILD)/ru_fixed.geojson $(VIZ_DIR)/after/ru.full.geojson
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
