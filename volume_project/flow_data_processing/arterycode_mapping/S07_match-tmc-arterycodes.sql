DELETE FROM prj_volume.artery_tcl WHERE match_on_case in (6,7,8);

--0.1 excludes geoids from centreline table where either:  segment type is not a road segment
DROP TABLE IF EXISTS excluded_geoids;
CREATE TEMPORARY TABLE excluded_geoids(centreline_id bigint);

INSERT INTO excluded_geoids
SELECT geo_id AS centreline_id
FROM gis.centreline
WHERE fcode_desc IN ('Geostatistical line', 'Hydro Line','Creek/Tributary','Major Railway','Major Shoreline','Minor Shoreline (Land locked)','Busway','River','Walkway','Ferry Route','Trail');

--0.2 generate a table of centreline nodes

DROP TABLE IF EXISTS centreline_nodes;
CREATE TEMPORARY TABLE centreline_nodes(node_id bigint primary key, shape geometry);

INSERT INTO centreline_nodes
SELECT fnode, ST_StartPoint(geom)
FROM gis.centreline
ON CONFLICT ON CONSTRAINT centreline_nodes_pkey DO NOTHING;

INSERT INTO centreline_nodes
SELECT tnode, ST_EndPoint(geom)
FROM gis.centreline
ON CONFLICT ON CONSTRAINT centreline_nodes_pkey DO NOTHING;

--0.3 generate a table of codes to be matched in this step
DROP TABLE IF EXISTS tmc_codes;
CREATE TEMPORARY TABLE tmc_codes(node_id bigint, loc geometry, arterycode bigint, found_in_tcl boolean);

INSERT INTO tmc_codes 
SELECT fnode_id as node_id, loc, arterycode, TRUE as found_in_tcl
FROM prj_volume.arteries 
INNER JOIN traffic.arterydata USING (arterycode)
WHERE count_type IN ('R','P') and arterycode NOT IN (SELECT DISTINCT arterycode FROM prj_volume.artery_tcl) and EXISTS(SELECT 1 FROM gis.centreline WHERE fnode_id = fnode or fnode_id = tnode);

INSERT INTO tmc_codes 
SELECT fnode_id as node_id, loc, arterycode, FALSE as found_in_tcl
FROM prj_volume.arteries 
INNER JOIN traffic.arterydata USING (arterycode)
WHERE count_type IN ('R','P') and arterycode NOT IN (SELECT DISTINCT arterycode FROM prj_volume.artery_tcl) and NOT EXISTS(SELECT 1 FROM gis.centreline WHERE fnode_id = fnode or fnode_id = tnode);

--0.4 snap node onto centreline nodes if node_id does not exist in centreline
UPDATE tmc_codes AS tc
SET node_id = sub.node_id
FROM 
	(SELECT DISTINCT ON (arterycode) arterycode, cn.node_id
	FROM (SELECT loc, arterycode FROM tmc_codes WHERE NOT found_in_tcl) an
		CROSS JOIN 
			centreline_nodes cn
	WHERE ST_DWithin(loc,shape,30)
	ORDER BY arterycode, ST_Distance(loc,shape)) as sub
WHERE tc.arterycode = sub.arterycode;

--1. match fnode and tnode

--1.1 find all tcl segments attached to intersection and assign direction if it's a major corridor
DROP TABLE IF EXISTS temp_match CASCADE;
CREATE TEMPORARY TABLE temp_match(arterycode bigint, centreline_id bigint, loc geometry, dir text, shape geometry, found_in_tcl boolean, linear_name_label text);

INSERT INTO temp_match
SELECT arterycode, centreline_id, loc, 
	NULL as dir,
	(CASE 
		WHEN node_id = from_intersection_id THEN shape
		ELSE ST_Reverse(shape)
	END) as shape, found_in_tcl, linear_name_label
FROM tmc_codes CROSS JOIN 
	     (SELECT ST_LineMerge(geom) as shape, geo_id AS centreline_id, fnode AS from_intersection_id, tnode AS to_intersection_id, lf_name AS linear_name_label FROM gis.centreline WHERE geo_id NOT IN (SELECT centreline_id FROM excluded_geoids)) sc
WHERE node_id = from_intersection_id or node_id = to_intersection_id;

UPDATE temp_match 
SET dir = 
	(CASE 
		WHEN (left(linear_name_label, -1) in (SELECT left(linear_name_label, -1) FROM prj_volume.corr_dir WHERE dir in ('NB','SB'))) and not (((ST_Azimuth(ST_StartPoint(shape), ST_LineInterpolatePoint(ST_LineMerge(shape), 0.1)) + 0.292) BETWEEN pi()*0.4 and 0.6*pi()) OR ((ST_Azimuth(ST_StartPoint(shape), ST_LineInterpolatePoint(ST_LineMerge(shape), 0.1)) + 0.292)  BETWEEN 1.4*pi() and 1.6*pi())) THEN 'NS'
		WHEN (left(linear_name_label, -1) in (SELECT left(linear_name_label, -1) FROM prj_volume.corr_dir WHERE dir in ('EB','WB'))) and not (((ST_Azimuth(ST_StartPoint(shape), ST_LineInterpolatePoint(ST_LineMerge(shape), 0.1)) + 0.292) <0.1*pi()) OR ((ST_Azimuth(ST_StartPoint(shape), ST_LineInterpolatePoint(ST_LineMerge(shape), 0.1)) + 0.292)  BETWEEN 0.9*pi() and 1.1*pi()) OR ((ST_Azimuth(ST_StartPoint(shape), ST_LineInterpolatePoint(ST_LineMerge(shape), 0.1)) + 0.292) > 1.9*pi())) THEN 'EW'
		ELSE NULL
	END);

CREATE VIEW ns_corr AS
SELECT arterycode, count(*) AS num
FROM temp_match
WHERE dir = 'NS'
GROUP BY arterycode;

CREATE VIEW ew_corr AS
SELECT arterycode, count(*) AS num
FROM temp_match
WHERE dir  = 'EW'
GROUP BY arterycode;

--1.2 assign direction to arterycode containing major corridors
UPDATE temp_match 
SET dir = 'NS'
WHERE dir is null and (SELECT num FROM ew_corr WHERE temp_match.arterycode = ew_corr.arterycode) = 2;

UPDATE temp_match 
SET dir = 'EW'
WHERE dir is null and (SELECT num FROM ns_corr WHERE temp_match.arterycode = ns_corr.arterycode) = 2;

-- reset direction if two major corridors of the same direction meet
UPDATE temp_match
SET dir = NULL
WHERE arterycode in ((SELECT arterycode FROM ew_corr WHERE num > 2) UNION (SELECT arterycode FROM ns_corr WHERE num > 2));

--1.3 assign direction to arterycode not containing major corridors
UPDATE temp_match
SET dir = calc_dirc(ST_LineMerge(shape),0.1)
WHERE dir is NULL;

--1.4 assign sideofint and insert

INSERT INTO prj_volume.artery_tcl
SELECT DISTINCT ON (arterycode, dir, sideofint)
	arterycode, centreline_id, 
	(CASE dir	
		WHEN 'NS' THEN 'Northbound'
		WHEN 'EW' THEN 'Eastbound'
	END) AS direction,
	(CASE dir 
		WHEN 'NS' THEN calc_side_ns(ST_Transform(loc,82181),ST_Transform(ST_LineMerge(shape),82181))
		WHEN 'EW' THEN calc_side_ew(ST_Transform(loc,82181),ST_Transform(ST_LineMerge(shape),82181))
	END) AS sideofint, 
	(CASE found_in_tcl 
		WHEN TRUE THEN 6
		ELSE 7
	END) AS match_on_case,
	2 as artery_type
FROM temp_match
ORDER BY arterycode, dir, sideofint, abs((ST_Azimuth(ST_StartPoint(shape), ST_LineInterpolatePoint(ST_LineMerge(shape), 0.1)) + 0.292)-round((ST_Azimuth(ST_StartPoint(shape), ST_LineInterpolatePoint(ST_LineMerge(shape), 0.1)) + 0.292)/(pi()/2))*(pi()/2))
ON CONFLICT ON CONSTRAINT artery_tcl_pkey DO
UPDATE SET centreline_id = EXCLUDED.centreline_id, match_on_case = EXCLUDED.match_on_case;


--2. match spatially (not an intersection)
INSERT INTO prj_volume.artery_tcl as atc
SELECT DISTINCT ON (arterycode, dir, sideofint)
	arterycode, centreline_id, 
	(CASE dir	
		WHEN 'NS' THEN 'Northbound'
		WHEN 'EW' THEN 'Eastbound'
	END) AS direction,
	(CASE dir 
		WHEN 'NS' THEN calc_side_ns(ST_Transform(loc,82181),ST_Transform(ST_LineMerge(shape),82181))
		WHEN 'EW' THEN calc_side_ew(ST_Transform(loc,82181),ST_Transform(ST_LineMerge(shape),82181))
	END) AS sideofint, 8 as match_on_case, 2 as artery_type
FROM (
	SELECT arterycode, calc_dirc(shape,0.1) as dir, centreline_id, loc, shape
	FROM (SELECT loc, arterycode FROM prj_volume.arteries WHERE tnode_id is NULL and arterycode NOT IN (SELECT DISTINCT arterycode FROM prj_volume.artery_tcl)) ar
		CROSS JOIN 
	     (SELECT geom AS shape, geo_id AS centreline_id FROM gis.centreline WHERE geo_id NOT IN (SELECT centreline_id FROM excluded_geoids)) sc 
	WHERE ST_DWithin(loc, shape, 15)
	ORDER BY arterycode, abs((ST_Azimuth(ST_StartPoint(shape), ST_EndPoint(shape)) + 0.292)-round((ST_Azimuth(ST_StartPoint(shape), ST_EndPoint(shape)) + 0.292)/(pi()/2))*(pi()/2))
	) AS sub
ON CONFLICT ON CONSTRAINT artery_tcl_pkey DO
UPDATE SET centreline_id = EXCLUDED.centreline_id, match_on_case = EXCLUDED.match_on_case;

--3. insert all failed instances (not within 30m to any intersection and not within 15m to any segment) (or segments not within 200m of anything else)
INSERT INTO prj_volume.artery_tcl(arterycode, sideofint, direction, match_on_case, artery_type)
SELECT arterycode, sideofint, apprdir as direction, 9 as match_on_case, 2 as artery_type
FROM prj_volume.arteries JOIN traffic.arterydata USING (arterycode)
WHERE arterycode NOT IN (SELECT DISTINCT arterycode FROM prj_volume.artery_tcl)
ON CONFLICT ON CONSTRAINT artery_tcl_pkey DO
UPDATE SET centreline_id = EXCLUDED.centreline_id, match_on_case = EXCLUDED.match_on_case;

--4. insert the other direction (south and west)
INSERT INTO prj_volume.artery_tcl
SELECT arterycode, centreline_id, 
		(CASE direction 
			WHEN 'Northbound' THEN 'Southbound'
			WHEN 'Eastbound' THEN 'Westbound'
		END) as direction, sideofint, match_on_case, artery_type
FROM prj_volume.artery_tcl
WHERE match_on_case in (6,7,8)
ON CONFLICT ON CONSTRAINT artery_tcl_pkey DO
UPDATE SET centreline_id = EXCLUDED.centreline_id, match_on_case = EXCLUDED.match_on_case;
