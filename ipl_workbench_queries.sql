-- RCB IPL Analytics — MySQL 8 | seasons 2013-2016 | RCB Team_Id = 2
USE ipl;

-- Q0. Performance setup: create indexes (run once)
SET @old_sql_notes := @@sql_notes;  SET sql_notes = 0;
DROP PROCEDURE IF EXISTS add_index_if_absent;
DELIMITER //
CREATE PROCEDURE add_index_if_absent(IN p_table VARCHAR(64), IN p_name VARCHAR(64), IN p_cols VARCHAR(255))
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.STATISTICS
                   WHERE TABLE_SCHEMA = DATABASE()
                     AND TABLE_NAME   = p_table
                     AND INDEX_NAME   = p_name) THEN
        SET @ddl = CONCAT('CREATE INDEX ', p_name, ' ON ', p_table, ' (', p_cols, ')');
        PREPARE s FROM @ddl; EXECUTE s; DEALLOCATE PREPARE s;
    END IF;
END //
DELIMITER ;
CALL add_index_if_absent('Ball_by_Ball', 'ix_bbb_striker', 'Striker');
CALL add_index_if_absent('Ball_by_Ball', 'ix_bbb_bowler',  'Bowler');
CALL add_index_if_absent('Ball_by_Ball', 'ix_bbb_batting', 'Team_Batting');
CALL add_index_if_absent('Ball_by_Ball', 'ix_bbb_bowling', 'Team_Bowling');
CALL add_index_if_absent('Matches',      'ix_m_season',    'Season_Id');
CALL add_index_if_absent('Matches',      'ix_m_venue',     'Venue_Id');
CALL add_index_if_absent('Matches',      'ix_m_winner',    'Match_Winner');
CALL add_index_if_absent('Player',       'ix_p_bowl',      'Bowling_skill');
CALL add_index_if_absent('Player_Match', 'ix_pm_player',   'Player_Id');
DROP PROCEDURE IF EXISTS add_index_if_absent;
SET sql_notes = @old_sql_notes;
-- Result: covering indexes created; no result grid.

-- Q0b. Reusable views (run once)
CREATE OR REPLACE VIEW v_ball_fact AS
SELECT b.Match_Id, b.Over_Id, b.Ball_Id, b.Innings_No,
       b.Striker, b.Bowler, b.Team_Batting, b.Team_Bowling,
       b.Runs_Scored,
       m.Season_Id, m.Venue_Id,
       er.Extra_Type_Id,
       CASE WHEN er.Extra_Type_Id = 2       THEN 0 ELSE 1 END AS is_ball_faced,
       CASE WHEN er.Extra_Type_Id IN (2,4)  THEN 0 ELSE 1 END AS is_legal_delivery,
       CASE WHEN b.Runs_Scored IN (4,6)     THEN 1 ELSE 0 END AS is_boundary,
       CASE WHEN w.Kind_Out IN (1,2,4,6,7,8) THEN 1 ELSE 0 END AS is_bowler_wicket
FROM   Ball_by_Ball b
JOIN   Matches m ON m.Match_Id = b.Match_Id
LEFT   JOIN Extra_Runs   er ON er.Match_Id=b.Match_Id AND er.Over_Id=b.Over_Id
                           AND er.Ball_Id=b.Ball_Id AND er.Innings_No=b.Innings_No
LEFT   JOIN Wicket_Taken w  ON w.Match_Id=b.Match_Id AND w.Over_Id=b.Over_Id
                           AND w.Ball_Id=b.Ball_Id AND w.Innings_No=b.Innings_No;

CREATE OR REPLACE VIEW v_batsman_career AS
SELECT f.Striker AS pid,
       SUM(f.Runs_Scored)                       AS runs,
       SUM(f.is_ball_faced)                     AS balls_faced,
       COUNT(DISTINCT f.Match_Id, f.Innings_No) AS innings
FROM   v_ball_fact f
GROUP  BY f.Striker;

CREATE OR REPLACE VIEW v_bowler_career AS
SELECT f.Bowler AS pid,
       SUM(f.is_bowler_wicket)                  AS wickets,
       COUNT(DISTINCT f.Match_Id, f.Innings_No) AS innings
FROM   v_ball_fact f
GROUP  BY f.Bowler;
-- Result: creates v_ball_fact, v_batsman_career, v_bowler_career; no result grid.

-- Q1. Data types of the columns in ball_by_ball
SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE, COLUMN_KEY
FROM   INFORMATION_SCHEMA.COLUMNS
WHERE  TABLE_SCHEMA = 'ipl' AND TABLE_NAME = 'ball_by_ball'
ORDER  BY ORDINAL_POSITION;
-- Result: each column of ball_by_ball with its data type.

-- Q2. RCB total runs in the earliest season (off-bat + extras)
SET @first_season := (SELECT MIN(Season_Id) FROM Matches);
SELECT s.Season_Year,
       bat.runs_off_bat,
       ex.extra_runs,
       bat.runs_off_bat + ex.extra_runs AS total_runs
FROM   Season s
JOIN ( SELECT m.Season_Id, SUM(b.Runs_Scored) AS runs_off_bat
       FROM   Ball_by_Ball b JOIN Matches m ON m.Match_Id = b.Match_Id
       WHERE  b.Team_Batting = 2 AND m.Season_Id = @first_season
       GROUP  BY m.Season_Id ) bat ON bat.Season_Id = s.Season_Id
JOIN ( SELECT m.Season_Id, COALESCE(SUM(er.Extra_Runs),0) AS extra_runs
       FROM   Extra_Runs er
       JOIN   Ball_by_Ball b ON b.Match_Id=er.Match_Id AND b.Over_Id=er.Over_Id
                            AND b.Ball_Id=er.Ball_Id AND b.Innings_No=er.Innings_No
       JOIN   Matches m ON m.Match_Id = b.Match_Id
       WHERE  b.Team_Batting = 2 AND m.Season_Id = @first_season
       GROUP  BY m.Season_Id ) ex ON ex.Season_Id = s.Season_Id;
-- Result: RCB 2013 runs off bat, extras, and total.

-- Q3. Players older than 25 during season 2014
SELECT COUNT(*) AS players_over_25_in_2014
FROM   Player p
WHERE  p.Player_Id IN ( SELECT pm.Player_Id
                        FROM Player_Match pm
                        JOIN Matches m ON m.Match_Id = pm.Match_Id
                        WHERE m.Season_Id = 7 )
  AND  p.DOB < DATE_SUB('2014-04-16', INTERVAL 25 YEAR);
-- Result: count of players over 25 in 2014.

-- Q4. Matches RCB won in 2013
SELECT COUNT(*) AS rcb_wins_2013
FROM   Matches m JOIN Season s ON s.Season_Id = m.Season_Id
WHERE  s.Season_Year = 2013 AND m.Match_Winner = 2;
-- Result: count of RCB wins in 2013.

-- Q5. Top 10 batsmen by strike rate, 2013-2016 (min 200 balls)
SELECT p.Player_Name,
       SUM(f.Runs_Scored)                                       AS runs,
       SUM(f.is_ball_faced)                                     AS balls_faced,
       ROUND(100.0 * SUM(f.Runs_Scored) / SUM(f.is_ball_faced), 2) AS strike_rate
FROM   v_ball_fact f
JOIN   Player p ON p.Player_Id = f.Striker
WHERE  f.Season_Id IN (6,7,8,9)
GROUP  BY f.Striker, p.Player_Name
HAVING balls_faced >= 200
ORDER  BY strike_rate DESC
LIMIT  10;
-- Result: top 10 batsmen ranked by strike rate.

-- Q6. Average runs per batsman (all seasons)
SELECT p.Player_Name,
       c.runs                             AS total_runs,
       c.innings,
       ROUND(c.runs / c.innings, 2)       AS avg_runs_per_innings
FROM   v_batsman_career c JOIN Player p ON p.Player_Id = c.pid
ORDER  BY avg_runs_per_innings DESC;
-- Result: each batsman's total runs, innings, and average.

-- Q7. Average wickets per bowler (all seasons)
SELECT p.Player_Name,
       c.wickets,
       c.innings                          AS innings_bowled,
       ROUND(c.wickets / c.innings, 3)    AS avg_wkts_per_innings
FROM   v_bowler_career c JOIN Player p ON p.Player_Id = c.pid
ORDER  BY avg_wkts_per_innings DESC;
-- Result: each bowler's wickets, innings, and average.

-- Q8. All-rounders above overall batting and bowling averages
WITH qbat  AS (SELECT pid, runs / innings AS avg_runs
               FROM v_batsman_career WHERE innings >= 10),
qbowl AS (SELECT pid, wickets / innings AS avg_wkts
               FROM v_bowler_career  WHERE innings >= 10),
ovr   AS (SELECT (SELECT AVG(avg_runs) FROM qbat)  AS oa_runs,
                 (SELECT AVG(avg_wkts) FROM qbowl) AS oa_wkts)
SELECT p.Player_Name,
       ROUND(qbat.avg_runs,2)  AS avg_runs,
       ROUND(qbowl.avg_wkts,3) AS avg_wkts
FROM   qbat
JOIN   qbowl ON qbowl.pid = qbat.pid
JOIN   Player p ON p.Player_Id = qbat.pid
CROSS  JOIN ovr
WHERE  qbat.avg_runs  > ovr.oa_runs
  AND  qbowl.avg_wkts > ovr.oa_wkts
ORDER  BY avg_runs DESC;
-- Result: players above both the overall batting and bowling averages.

-- Q9. Create rcb_record: RCB wins & losses per venue
DROP TABLE IF EXISTS rcb_record;
CREATE TABLE rcb_record AS
SELECT v.Venue_Name,
       SUM(CASE WHEN m.Match_Winner = 2 THEN 1 ELSE 0 END) AS wins,
       SUM(CASE WHEN (m.Team_1=2 OR m.Team_2=2)
                 AND m.Match_Winner <> 2
                 AND m.Match_Winner IS NOT NULL THEN 1 ELSE 0 END) AS losses,
       SUM(CASE WHEN m.Team_1=2 OR m.Team_2=2 THEN 1 ELSE 0 END)   AS played
FROM   Matches m JOIN Venue v ON v.Venue_Id = m.Venue_Id
WHERE  m.Team_1 = 2 OR m.Team_2 = 2
GROUP  BY v.Venue_Name
ORDER  BY wins DESC, played DESC;
SELECT * FROM rcb_record;
-- Result: RCB wins, losses, and games played per venue.

-- Q10. Wickets taken by bowling style
SELECT bs.Bowling_skill AS bowling_style,
       COUNT(DISTINCT f.Bowler)                 AS bowlers,
       SUM(f.is_bowler_wicket)                  AS wickets,
       ROUND(SUM(f.is_bowler_wicket) / COUNT(DISTINCT f.Bowler), 1) AS wkts_per_bowler
FROM   v_ball_fact f
JOIN   Player p         ON p.Player_Id  = f.Bowler
JOIN   Bowling_Style bs ON bs.Bowling_Id = p.Bowling_skill
GROUP  BY bs.Bowling_skill
ORDER  BY wickets DESC;
-- Result: wickets and bowler count per bowling style.

-- Q11. Is each season better than the previous (runs & wickets)
WITH rcb_bat AS (
    SELECT m.Season_Id, SUM(b.Runs_Scored) AS runs
    FROM Ball_by_Ball b JOIN Matches m ON m.Match_Id=b.Match_Id
    WHERE b.Team_Batting = 2 GROUP BY m.Season_Id ),
rcb_extra AS (
    SELECT m.Season_Id, COALESCE(SUM(er.Extra_Runs),0) AS extras
    FROM Extra_Runs er
    JOIN Ball_by_Ball b ON b.Match_Id=er.Match_Id AND b.Over_Id=er.Over_Id
                       AND b.Ball_Id=er.Ball_Id AND b.Innings_No=er.Innings_No
    JOIN Matches m ON m.Match_Id=b.Match_Id
    WHERE b.Team_Batting = 2 GROUP BY m.Season_Id ),
rcb_wkts AS (
    SELECT m.Season_Id, COUNT(*) AS wkts
    FROM Wicket_Taken w
    JOIN Ball_by_Ball b ON b.Match_Id=w.Match_Id AND b.Over_Id=w.Over_Id
                       AND b.Ball_Id=w.Ball_Id AND b.Innings_No=w.Innings_No
    JOIN Matches m ON m.Match_Id=b.Match_Id
    WHERE b.Team_Bowling = 2 GROUP BY m.Season_Id )
SELECT s.Season_Year,
       (rb.runs + re.extras)                                                AS runs,
       (rb.runs + re.extras) - LAG(rb.runs + re.extras) OVER (ORDER BY s.Season_Year) AS runs_delta,
       w.wkts,
       w.wkts - LAG(w.wkts) OVER (ORDER BY s.Season_Year)                   AS wkts_delta,
       CASE WHEN LAG(rb.runs+re.extras) OVER (ORDER BY s.Season_Year) IS NULL THEN 'Baseline'
            WHEN (rb.runs+re.extras) > LAG(rb.runs+re.extras) OVER (ORDER BY s.Season_Year)
             AND w.wkts > LAG(w.wkts) OVER (ORDER BY s.Season_Year) THEN 'Better (both up)'
            WHEN (rb.runs+re.extras) < LAG(rb.runs+re.extras) OVER (ORDER BY s.Season_Year)
             AND w.wkts < LAG(w.wkts) OVER (ORDER BY s.Season_Year) THEN 'Worse (both down)'
            ELSE 'Mixed' END                                                AS status
FROM   rcb_bat rb
JOIN   rcb_extra re ON re.Season_Id = rb.Season_Id
JOIN   rcb_wkts  w  ON w.Season_Id  = rb.Season_Id
JOIN   Season    s  ON s.Season_Id  = rb.Season_Id
ORDER  BY s.Season_Year;
-- Result: per-season runs and wickets with change vs the previous season.

-- Q12a. RCB batting profile: boundary %, dot %, run rate
SELECT 'RCB' AS team,
       ROUND(100.0*SUM(f.is_boundary) / SUM(f.is_ball_faced),2) AS boundary_pct,
       ROUND(100.0*SUM(CASE WHEN COALESCE(f.Runs_Scored,0)=0
                             AND (f.Extra_Type_Id IS NULL OR f.Extra_Type_Id NOT IN (2,4)) THEN 1 ELSE 0 END)
             / SUM(f.is_legal_delivery),2) AS dot_pct,
       ROUND(6.0*SUM(f.Runs_Scored) / SUM(f.is_legal_delivery),2) AS run_rate
FROM   v_ball_fact f
WHERE  f.Team_Batting = 2 AND f.Innings_No IN (1,2);
-- Result: RCB boundary %, dot %, and run rate.

-- Q12b. RCB run-rate vs bowling economy by phase
SELECT CASE WHEN f.Over_Id<=6 THEN '1 Powerplay (1-6)'
            WHEN f.Over_Id<=15 THEN '2 Middle (7-15)'
            ELSE '3 Death (16-20)' END AS phase,
       ROUND(6.0*SUM(CASE WHEN f.Team_Batting=2 THEN f.Runs_Scored ELSE 0 END)
             / NULLIF(SUM(CASE WHEN f.Team_Batting=2 THEN f.is_legal_delivery ELSE 0 END),0),2) AS rcb_bat_run_rate,
       ROUND(6.0*SUM(CASE WHEN f.Team_Bowling=2 THEN f.Runs_Scored ELSE 0 END)
             / NULLIF(SUM(CASE WHEN f.Team_Bowling=2 THEN f.is_legal_delivery ELSE 0 END),0),2) AS rcb_bowl_economy
FROM   v_ball_fact f
WHERE  f.Innings_No IN (1,2)
GROUP  BY phase ORDER BY phase;
-- Result: run-rate and economy for powerplay, middle, and death overs.

-- Q13. Bowlers ranked by average wickets within each venue
WITH agg AS (
    SELECT v.Venue_Name, p.Player_Name,
           SUM(f.is_bowler_wicket) AS wickets,
           COUNT(DISTINCT f.Match_Id, f.Innings_No) AS innings,
           ROUND(SUM(f.is_bowler_wicket)/COUNT(DISTINCT f.Match_Id, f.Innings_No),3) AS avg_wkts
    FROM v_ball_fact f
    JOIN Player p ON p.Player_Id=f.Bowler
    JOIN Venue v ON v.Venue_Id=f.Venue_Id
    GROUP BY v.Venue_Name, p.Player_Name
    HAVING SUM(f.is_bowler_wicket) >= 5 )
SELECT Venue_Name, Player_Name, wickets, innings, avg_wkts,
       RANK() OVER (PARTITION BY Venue_Name ORDER BY avg_wkts DESC) AS rank_at_venue
FROM   agg
ORDER  BY Venue_Name, rank_at_venue;
-- Result: bowlers ranked by average wickets at each venue.

-- Q14. Batsmen with 250+ runs in every season (consistency)
WITH per_season AS (
    SELECT f.Striker AS pid, f.Season_Id, SUM(f.Runs_Scored) AS runs
    FROM v_ball_fact f
    GROUP BY f.Striker, f.Season_Id )
SELECT p.Player_Name,
       COUNT(*)                                   AS seasons_played,
       SUM(ps.runs)                               AS total_runs,
       ROUND(AVG(ps.runs),1)                      AS avg_season_runs,
       ROUND((MAX(ps.runs)-MIN(ps.runs))/AVG(ps.runs),2) AS spread_ratio
FROM   per_season ps JOIN Player p ON p.Player_Id = ps.pid
GROUP  BY ps.pid, p.Player_Name
HAVING seasons_played = 4 AND MIN(ps.runs) >= 250
ORDER  BY avg_season_runs DESC;
-- Result: consistent batsmen (250+ runs each season) with spread ratio.

-- Q14b. Per-season runs for those consistent batsmen
WITH per_season AS (
    SELECT f.Striker AS pid, f.Season_Id, SUM(f.Runs_Scored) AS runs
    FROM v_ball_fact f
    GROUP BY f.Striker, f.Season_Id ),
consistent AS (
    SELECT pid FROM per_season
    GROUP BY pid HAVING COUNT(*)=4 AND MIN(runs) >= 250 )
SELECT p.Player_Name, s.Season_Year, ps.runs
FROM   per_season ps
JOIN   consistent c ON c.pid = ps.pid
JOIN   Player p ON p.Player_Id = ps.pid
JOIN   Season s ON s.Season_Id = ps.Season_Id
ORDER  BY p.Player_Name, s.Season_Year;
-- Result: season-by-season runs for each consistent batsman.

-- Q15. Batsman x venue with 250+ runs (venue suitability)
SELECT p.Player_Name, v.Venue_Name,
       SUM(f.Runs_Scored) AS runs,
       ROUND(100.0*SUM(f.Runs_Scored)/SUM(f.is_ball_faced),1) AS strike_rate
FROM   v_ball_fact f
JOIN   Player p ON p.Player_Id = f.Striker
JOIN   Venue v  ON v.Venue_Id  = f.Venue_Id
GROUP  BY f.Striker, f.Venue_Id, p.Player_Name, v.Venue_Name
HAVING runs >= 250
ORDER  BY runs DESC
LIMIT  15;
-- Result: top batsman-venue pairs by runs with strike rate.

-- Subjective support queries

-- S1. Match win % by toss decision
SELECT td.Toss_Name AS toss_decision,
       COUNT(*) AS matches,
       SUM(CASE WHEN m.Match_Winner = m.Toss_Winner THEN 1 ELSE 0 END) AS toss_winner_won,
       ROUND(100.0*SUM(CASE WHEN m.Match_Winner=m.Toss_Winner THEN 1 ELSE 0 END)/COUNT(*),1) AS win_pct
FROM   Matches m JOIN Toss_Decision td ON td.Toss_Id = m.Toss_Decide
WHERE  m.Match_Winner IS NOT NULL
GROUP  BY td.Toss_Name;
-- Result: matches and win % for each toss decision.

-- S4. Versatile players: 500+ career runs and 25+ wickets
SELECT p.Player_Name, bat.runs, bowl.wickets AS wkts
FROM   v_batsman_career bat
JOIN   v_bowler_career  bowl ON bowl.pid = bat.pid
JOIN   Player p ON p.Player_Id = bat.pid
WHERE  bat.runs >= 500 AND bowl.wickets >= 25
ORDER  BY bat.runs DESC;
-- Result: players with both 500+ runs and 25+ wickets.

-- S5. Top 10 players by Man-of-the-Match awards
SELECT p.Player_Name, COUNT(*) AS mom_awards
FROM   Matches m
JOIN   Player p ON p.Player_Id = m.Man_of_the_Match
WHERE  m.Man_of_the_Match IS NOT NULL
GROUP  BY m.Man_of_the_Match, p.Player_Name
ORDER  BY mom_awards DESC
LIMIT  10;
-- Result: top 10 players by Man-of-the-Match awards.

-- S8. RCB home vs away win %
SELECT CASE WHEN m.Venue_Id = 1 THEN 'Home (Chinnaswamy)' ELSE 'Away / Neutral' END AS ground,
       COUNT(*) AS played,
       SUM(CASE WHEN m.Match_Winner=2 THEN 1 ELSE 0 END) AS won,
       ROUND(100.0*SUM(CASE WHEN m.Match_Winner=2 THEN 1 ELSE 0 END)/COUNT(*),1) AS win_pct
FROM   Matches m
WHERE (m.Team_1=2 OR m.Team_2=2) AND m.Match_Winner IS NOT NULL
GROUP  BY ground;
-- Result: RCB games and win % for home vs away.

-- S9. Create rcb_season_summary: played / won / lost / win %
DROP TABLE IF EXISTS rcb_season_summary;
CREATE TABLE rcb_season_summary (
    Season_Year INT PRIMARY KEY, Played INT, Won INT, Lost INT, Win_Pct DECIMAL(5,1) );
INSERT INTO rcb_season_summary (Season_Year, Played, Won, Lost, Win_Pct)
SELECT s.Season_Year,
       SUM(CASE WHEN m.Team_1=2 OR m.Team_2=2 THEN 1 ELSE 0 END),
       SUM(CASE WHEN m.Match_Winner=2 THEN 1 ELSE 0 END),
       SUM(CASE WHEN (m.Team_1=2 OR m.Team_2=2) AND m.Match_Winner<>2
                 AND m.Match_Winner IS NOT NULL THEN 1 ELSE 0 END),
       ROUND(100.0*SUM(CASE WHEN m.Match_Winner=2 THEN 1 ELSE 0 END)
             / NULLIF(SUM(CASE WHEN m.Team_1=2 OR m.Team_2=2 THEN 1 ELSE 0 END),0),1)
FROM   Matches m JOIN Season s ON s.Season_Id=m.Season_Id
GROUP  BY s.Season_Year;
SELECT * FROM rcb_season_summary ORDER BY Season_Year;
-- Result: RCB played / won / lost / win % per season.

-- S11. Data-cleaning: rename Delhi Capitals -> Delhi Daredevils
SET SQL_SAFE_UPDATES = 0;
UPDATE Team
SET    Team_Name = 'Delhi Daredevils'
WHERE  Team_Name = 'Delhi Capitals';
SET SQL_SAFE_UPDATES = 1;
-- Result: Team row renamed; no result grid.
