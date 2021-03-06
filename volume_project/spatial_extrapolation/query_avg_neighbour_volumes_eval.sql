-- Parameters: $1 - feature_code; $2 - sample size

WITH segments AS (
	SELECT group_number, dir_bin, place_holder_time_var, AVG(volume) AS volume, shape, feature_code
	FROM prj_volume.place_holder_table_name JOIN prj_volume.centreline_groups_geom USING (group_number)
	WHERE confidence = 1
	GROUP BY group_number, feature_code, shape, place_holder_time_var)

SELECT g1, dir_bin, place_holder_time_var, AVG(neighbourvolume)::int, volume::int
FROM (SELECT l1.group_number AS g1, l1.volume as volume, l1.dir_bin as dir_bin, l2.volume as neighbourvolume, place_holder_time_var, row_number() OVER (PARTITION BY l1.group_number,l1.volume ORDER BY ST_Distance(l1.shape, l2.shape))
	FROM segments l1, segments l2
	WHERE ST_DWithin(l1.shape, l2.shape, 500) AND l1.group_number != l2.group_number AND l1.feature_code=$1 AND l2.feature_code=$1) A 
WHERE row_number < 5
GROUP BY g1, place_holder_time_var, volume
ORDER BY random()
LIMIT (SELECT COUNT(*) FROM segments WHERE feature_code=$1)*$2/100