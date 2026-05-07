

CONTINENTS='Europe', 'Asia','Africa'
REGIONS='ES', 'IT'
PRECISION=10m
PRECISIONREG=10m

start-server:
	python3 -m http.server 8000

download:
	if [ ! -f ne_$(PRECISION)_admin_0_countries.zip ]; then curl -L -o ne_$(PRECISION)_admin_0_countries.zip https://naciscdn.org/naturalearth/$(PRECISION)/cultural/ne_$(PRECISION)_admin_0_countries.zip; fi
	if [ ! -f ne_$(PRECISIONREG)_admin_1_states_provinces.zip ]; then curl -L -o ne_$(PRECISIONREG)_admin_1_states_provinces.zip https://naciscdn.org/naturalearth/$(PRECISIONREG)/cultural/ne_$(PRECISIONREG)_admin_1_states_provinces.zip; fi

data: download
	rm -f countries.geojson states.geojson
	rm -f map.geojson
	#ogr2ogr -f GeoJSON -makevalid -lco COORDINATE_PRECISION=2 -sql "SELECT 'country' as level, NAME as name, ISO_A2_EH as iso, TYPE as type, WIKIDATAID as wikidataid FROM ne_$(PRECISION)_admin_0_countries WHERE CONTINENT IN (${CONTINENTS})" countries.geojson /vsizip/ne_$(PRECISION)_admin_0_countries.zip
	#ogr2ogr -f GeoJSON -makevalid -lco COORDINATE_PRECISION=2 -sql "SELECT 'region' as level, name_en as name, iso_3166_2 as iso, type_en as type, wikidataid as wikidataid FROM ne_$(PRECISIONREG)_admin_1_states_provinces WHERE ISO_A2 IN (${REGIONS})" states.geojson /vsizip/ne_$(PRECISIONREG)_admin_1_states_provinces.zip
	ogr2ogr -f GeoJSON -makevalid -nln merged -lco COORDINATE_PRECISION=2 \
	  -sql "SELECT 'country' as level, NAME as name, ISO_A2_EH as iso, CONTINENT as parent FROM ne_$(PRECISION)_admin_0_countries WHERE CONTINENT IN (${CONTINENTS}) AND TYPE != 'Dependency'" map.geojson /vsizip/ne_$(PRECISION)_admin_0_countries.zip
	#ogr2ogr -f GeoJSON -makevalid -append -nln merged -lco COORDINATE_PRECISION=2 \
	#  -sql "SELECT 'region' as level, name_en as name, iso_3166_2 as iso, type_en as type, wikidataid as wikidataid, ISO_A2 as parent FROM ne_$(PRECISIONREG)_admin_1_states_provinces WHERE ISO_A2 IN (${REGIONS})" map.geojson /vsizip/ne_$(PRECISIONREG)_admin_1_states_provinces.zip
	ogr2ogr -f GeoJSON -makevalid -append -nln merged -lco COORDINATE_PRECISION=2 \
	  -dialect SQLite \
	  -sql "SELECT \
		'region' as level, \
		MIN(name_en) as name, \
		REPLACE(code_hasc, '.', '-') as iso, \
		ISO_A2 as parent, \
		ST_Union(geometry) as geometry \
		FROM ne_$(PRECISIONREG)_admin_1_states_provinces \
		WHERE \
		ISO_A2 IN (${REGIONS}) \
		GROUP BY code_hasc, ISO_A2 \
		" map.geojson /vsizip/ne_$(PRECISIONREG)_admin_1_states_provinces.zip
