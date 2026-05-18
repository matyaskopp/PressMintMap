

CONTINENTS='Europe', 'Asia','Africa'
REGIONS='ES', 'IT', 'UA', 'RU'
PRECISION=10m
PRECISIONREG=10m

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
	    ISO_A2 as parent, \
	    geometry \
	  FROM ne_$(PRECISIONREG)_admin_1_states_provinces \
	  WHERE ISO_A2 IN (${REGIONS})" \
	  states.geojson \
	  /vsizip/ne_$(PRECISIONREG)_admin_1_states_provinces.zip




fix-crimea: sources
	rm -rf tmp
	mkdir -p tmp

	rm -f crimea.geojson \
	      ru.geojson \
	      ru_fixed.geojson \
	      ua.geojson \
	      ua_fixed.geojson

	# Extract Crimea from Admin1
	jq '{type:"FeatureCollection", features:[.features[] | select(.properties.iso | IN("UA-KR", "UA-SC"))]}' \
		states.geojson > crimea.geojson
	#npx mapshaper states.geojson \
	#  -filter 'iso=="UA-KR"' \
	#  -each 'parent="UA"' \
	#  -o crimea.geojson

	# Extract Russia
	jq '{type:"FeatureCollection", features:[.features[] | select(.properties.iso=="RU")]}' \
		countries.geojson > ru.geojson
	#npx mapshaper countries.geojson \
	#  -filter 'iso=="RU"' \
	#  -o ru.geojson

	# Remove Crimea from Russia
	#npx mapshaper ru.geojson \
	#  -erase source=crimea.geojson \
	#  -o ru_fixed.geojson
	jq " \
 		[ \
 		  .features[] \
 		  | select(.properties.parent == \"RU\" and .properties.iso != \"UA-KR\" and .properties.iso != \"UA-SC\") \
 		] as \$$ru_regions \
 		| \
 		{ \
 		  type: \"FeatureCollection\", \
 		  features: [ \
 		    { \
 		      type: \"Feature\", \
 		      properties: { \
 		        iso: \"RU\", \
 		        level: \"country\", \
 		        name: \"Russia\", \
 		        parent: \"Europe\" \
 		      }, \
 		      geometry: { \
 		        type: \"MultiPolygon\", \
 		        coordinates: ( \
 		          \$$ru_regions \
 		          | map( \
 		              if .geometry.type == \"Polygon\" \
 		              then [.geometry.coordinates] \
 		              else .geometry.coordinates \
 		              end \
 		            ) \
 		          | add \
 		        ) \
 		      } \
 		    } \
 		  ] \
 		} \
 		" states.geojson > ru_fixed.geojson




	# Extract Ukraine
	jq '{type:"FeatureCollection", features:[.features[] | select(.properties.iso=="UA")]}' \
		countries.geojson > ua.geojson
	#npx mapshaper countries.geojson \
	#  -filter 'iso=="UA"' \
	#  -o ua.geojson
  
	# Merge Crimea into Ukraine
	#npx mapshaper \
	#  crimea.geojson \
	#  ua.geojson \
	#  -merge-layers \
	#  -o ua_fixed.geojson

	jq "\
		def normalize: \
		  if .geometry.type == \"Polygon\" then \
		    [.geometry.coordinates] \
		  else \
		    .geometry.coordinates \
		  end; \
		 \
		def ua: .features[0]; \
		def cr: input.features[0]; \
		 \
		{ \
		  type: \"FeatureCollection\", \
		  features: [ \
		    (ua | .geometry.type = \"MultiPolygon\" \
		        | .geometry.coordinates = (normalize + (cr | normalize))) \
		  ] \
		} \
		" ua.geojson crimea.geojson > ua_fixed.geojson

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
  
