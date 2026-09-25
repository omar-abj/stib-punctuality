/*=============================================================================
  TFE STIB - 00_ddl/05_ref_feed_periode.sql
  ----------------------------------------------------------------------------
  OBJET : dire, pour chaque date, QUEL feed GTFS fait autorite.
  Grain : 1 ligne = 1 feed_version, avec sa periode d'application.

  POURQUOI CETTE TABLE EXISTE
  ----------------------------------------------------------------------------
  Les trois feeds GTFS publies par la STIB se chevauchent :

      2_15  |========================|                        22/06 -> 19/07
      2_16              |========================|            06/07 -> 02/08
      2_18                          |=======================| 03/08 -> 30/08

  Du 6 au 19 juillet, deux feeds proposent un horaire theorique pour la
  meme date. Sans regle, une jointure ramenerait les deux et DUPLIQUERAIT
  les passages theoriques, sans aucune erreur SQL.

  REGLE : le feed le plus recent couvrant la date fait autorite. C'est
  celui qui integre les dernieres modifications de service connues au
  moment de sa publication. Elle se traduit en bornes NON CHEVAUCHANTES :
  chaque date tombe dans exactement un intervalle.

  Une table plutot qu'une regle reimplementee dans chaque requete : la
  decision est prise en UN seul endroit, et toutes les jointures stg_* et
  map_destination passent par ici.

  POURQUOI LE 2_15 COMMENCE LE 01/07 ET NON LE 22/06
  ----------------------------------------------------------------------------
  La collecte temps reel commence le 1er juillet. Les dates anterieures ne
  correspondent a aucun passage observe. Borner au 01/07 rend le controle
  C3 plus lisible : toute date sans feed est alors une vraie anomalie.

  LIMITE CONNUE : le 31 aout n'est couvert par aucun feed (la version 2_17
  n'a pas ete recuperee). Sans effet : le perimetre d'analyse s'arrete au
  26/08.

  SAISIE MANUELLE : les trois chaines feed_version doivent correspondre
  EXACTEMENT a celles chargees dans stg_* (controle C1).

  PREREQUIS  : stg_calendar chargee (controle C1), wrk_passages (C3, optionnel)
  IDEMPOTENT : DROP puis CREATE.
  ORIGINE    : session du 19/08/2026, extrait en fichier le 25/09/2026.
=============================================================================*/

USE TFE_STIB;
GO

DROP TABLE IF EXISTS dbo.ref_feed_periode;

CREATE TABLE dbo.ref_feed_periode (
    feed_version VARCHAR(50) NOT NULL PRIMARY KEY,
    date_debut   DATE        NOT NULL,
    date_fin     DATE        NOT NULL
);

INSERT INTO dbo.ref_feed_periode (feed_version, date_debut, date_fin) VALUES
    ('2_15_20260622_010638', '2026-07-01', '2026-07-05'),
    ('2_16_20260706_010641', '2026-07-06', '2026-08-02'),
    ('2_18_20260803_010656', '2026-08-03', '2026-08-30');
GO


/*=============================================================================
  CONTROLES
=============================================================================*/

PRINT '=== C1 - Les feed_version saisis existent-ils dans le GTFS charge ? ===';
-- Attendu : 3 lignes 'OK'. Une faute de frappe donnerait 'ABSENT', et toutes
-- les jointures sur ce feed renverraient zero ligne, silencieusement.
SELECT  r.feed_version, r.date_debut, r.date_fin,
        CASE WHEN c.feed_version IS NULL THEN 'ABSENT DE stg_calendar'
             ELSE 'OK' END AS controle
FROM        dbo.ref_feed_periode AS r
LEFT JOIN  (SELECT DISTINCT feed_version FROM dbo.stg_calendar) AS c
        ON  c.feed_version = r.feed_version;

PRINT '=== C2 - Aucun chevauchement ===';
-- Attendu : 0 ligne. Un chevauchement dupliquerait les passages theoriques.
SELECT  a.feed_version AS feed_a, b.feed_version AS feed_b
FROM    dbo.ref_feed_periode AS a
JOIN    dbo.ref_feed_periode AS b
  ON    a.feed_version < b.feed_version
 AND    a.date_debut  <= b.date_fin
 AND    b.date_debut  <= a.date_fin;

PRINT '=== C3 - Chaque jour collecte a-t-il un feed ? ===';
-- Attendu : 0 ligne. A lancer une fois wrk_passages construite (22).
SELECT  CAST(p.derniere_obs AS DATE) AS jour, COUNT(*) AS nb_passages
FROM        dbo.wrk_passages     AS p
LEFT JOIN   dbo.ref_feed_periode AS f
       ON   CAST(p.derniere_obs AS DATE) BETWEEN f.date_debut AND f.date_fin
WHERE       f.feed_version IS NULL
GROUP BY    CAST(p.derniere_obs AS DATE)
ORDER BY    jour;
GO
