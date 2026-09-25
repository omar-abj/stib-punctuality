/*=============================================================================
  TFE STIB - 70_analyse/70_analyse_spatiale.sql
  ----------------------------------------------------------------------------
  OBJET : produire les deux tables qui alimentent les trois visuels
          de la question "ou, le long d'un parcours, le temps se
          perd-il ?".

  SORTIES :
    dbo.int_profil_arret   1 ligne = direction x arret
                           -> visuel 1 : le retard le long de la ligne
    dbo.int_segment        1 ligne = direction x segment (A -> B)
                           -> visuel 2 : le delta par segment
                           -> visuel 3 : delta median vs ecart-type

  Parametre : #param.ligne. '25' pour la ligne de developpement,
  NULL pour les 75 lignes du reseau.

  ⚠️ En mode reseau, LIRE H1b AVANT TOUT : la regle d'adjacence
     n'a ete validee que sur la ligne 25, et les lignes a branches
     (87, 4, 1, 51, 93 - reserve B2) n'ont jamais ete confrontees
     au code.

  ----------------------------------------------------------------------------
  ⚠️ TROIS PIEGES EVITES ICI
  ----------------------------------------------------------------------------
  1. L'ORDRE DE PARCOURS N'EST PAS ordre_geo.
     En direction 1, ordre_geo DECROIT le long du trajet (mesure du
     03/09 : PATRIE 90, MEISER 100, alors que le tram va de PATRIE
     vers MEISER). Un LAG ordonne par ordre_geo inverse donc le signe
     des deltas d'une direction sur deux - constate en direct.
     -> On ordonne par theorique_sec, l'heure de passage prevue.
        C'est l'ordre de marche reel, quelle que soit la direction.
     ordre_geo ne sert plus qu'a ETIQUETER.

     ⚠️ COROLLAIRE, MESURE LE 03/09 : ordre_geo N'A PAS UN PAS
     CONSTANT. Sur la ligne 25 il avance de 10 en 10 (170, 180, 190),
     d'ou une premiere version qui exigeait ABS(diff) = 10 pour
     declarer deux arrets consecutifs. C'etait une GENERALISATION
     ABUSIVE a partir d'une seule ligne : la 95 comporte des pas de
     1 (LEVURE, FLAGEY, MUSEE D'IXELLES... numerotes 151 a 155), de
     5 et de 8. La condition tuait 9 segments sur cette ligne, EN
     SILENCE, et 145 sur le reseau (couverture 95,5 %).
     -> La condition est SUPPRIMEE. Deux passages successifs d'une
        MEME course un MEME jour sont consecutifs par construction :
        la partition ne contient que les arrets de cette course.
        L'ecart de rang est desormais PUBLIE comme attribut
        (saut_de_rang) au lieu de servir de filtre.

  2. DELTA PAR COURSE, PAS MOYENNE DES RETARDS PAR ARRET (piege n°52).
     Moyenner les retards de tous les passages a chaque arret puis
     soustraire ne donne PAS le temps perdu sur le troncon : ce sont
     deux populations differentes. Mesure du 27/08 : +17/+19 par la
     mauvaise methode, +24/+24 par la bonne.

  3. UN SEGMENT SE PARTITIONNE PAR SON COUPLE D'ARRETS, jamais par
     le seul arret d'arrivee. Une ligne a variantes de trace fait
     converger plusieurs predecesseurs vers un meme arret : la cle
     par arrivee demultiplie alors chaque segment. Detail complet
     dans la CTE 'agrege'.

  4. PERCENTILE_CONT N'EXISTE QU'EN FONCTION FENETRE en T-SQL
     (piege n°53). Elle renvoie une valeur PAR LIGNE, d'ou le
     GROUP BY impossible et le passage par une CTE + DISTINCT.

  ⚠️ retard_sec est CENSURE a +/- tolerance_sec (300 s sur la 25).
     Les medianes de segment sont donc des estimations basses des
     ecarts extremes. Sans effet sur la LECTURE RELATIVE des
     segments entre eux, qui est le sujet ici.

  ENTREES : dbo.fact_ecart, dbo.dim_desserte, dbo.dim_ligne
  IDEMPOTENT : les deux tables sont reconstruites integralement.
=============================================================================*/

USE TFE_STIB;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

/*----------------------------------------------------------------------------
  LE PARAMETRE PASSE PAR UNE TABLE TEMPORAIRE, PAS PAR UN DECLARE.
  ----------------------------------------------------------------------------
  DECLARE ne survit pas a un GO : chaque GO ouvre un nouveau batch et
  la variable disparait. Le script echouait avec "Must declare the
  scalar variable @ligne" a la premiere reutilisation apres un GO.
  Une table #param traverse les batches tant que la session est
  ouverte. (Nouveau piege, a ajouter au catalogue.)

    '25'  -> ligne de developpement, cas sur, 51 arrets
    NULL  -> tout le reseau, 75 lignes  ⚠️ voir le controle H1b
----------------------------------------------------------------------------*/

DROP TABLE IF EXISTS #param;
CREATE TABLE #param (ligne VARCHAR(10) NULL);
INSERT INTO #param (ligne) VALUES (NULL);   -- <<< METTRE NULL POUR LE RESEAU
GO


/*=============================================================================
  1. LA BASE COMMUNE : les passages apparies, situes et ordonnes
=============================================================================*/

DROP TABLE IF EXISTS #passage;

SELECT      l.line_id,
            l.route_type,
            f.course_sk,
            f.date_sk,
            d.direction_id,
            d.ordre_geo,
            d.stop_name,
            d.libelle_affichage,
            d.stop_id_racine,
            f.theorique_sec,
            f.retard_sec
INTO        #passage
FROM        dbo.fact_ecart   AS f
INNER JOIN  dbo.dim_desserte AS d ON d.desserte_sk = f.desserte_sk
INNER JOIN  dbo.dim_ligne    AS l ON l.ligne_sk    = f.ligne_sk
WHERE       f.statut_appariement = 'apparie'
  AND       f.course_sk    <> -1      -- il faut une course pour suivre un vehicule
  AND       f.desserte_sk  <> -1      -- il faut une position pour situer l'arret
  AND       f.theorique_sec IS NOT NULL
  AND       EXISTS (SELECT 1 FROM #param AS pa
                    WHERE pa.ligne IS NULL OR pa.ligne = l.line_id);

CREATE CLUSTERED INDEX ix_passage
    ON #passage (course_sk, date_sk, theorique_sec);
GO


/*=============================================================================
  2. int_profil_arret - VISUEL 1
  ----------------------------------------------------------------------------
  Le retard median a chaque arret, par direction. En X : ordre_geo.
  En Y : retard_median_sec. Une courbe par direction.

  CE QU'IL FAUT Y VOIR : une derive qui s'ACCUMULE le long du
  parcours, ou au contraire des sauts localises. Une derive continue
  plaide pour un horaire mal calibre sur toute la ligne ; un saut
  designe un troncon precis.
=============================================================================*/

DROP TABLE IF EXISTS dbo.int_profil_arret;

;WITH par_arret AS (
    SELECT DISTINCT
            p.line_id,
            p.route_type,
            p.direction_id,
            p.ordre_geo,
            p.stop_name,
            p.libelle_affichage,
            p.stop_id_racine,
            n_passages = COUNT(*) OVER (PARTITION BY p.line_id, p.direction_id, p.ordre_geo, p.stop_id_racine),
            retard_median_sec = PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY p.retard_sec)
                                OVER (PARTITION BY p.line_id, p.direction_id, p.ordre_geo, p.stop_id_racine),
            retard_p10_sec    = PERCENTILE_CONT(0.10) WITHIN GROUP (ORDER BY p.retard_sec)
                                OVER (PARTITION BY p.line_id, p.direction_id, p.ordre_geo, p.stop_id_racine),
            retard_p90_sec    = PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY p.retard_sec)
                                OVER (PARTITION BY p.line_id, p.direction_id, p.ordre_geo, p.stop_id_racine),
            retard_moyen_sec  = AVG(CAST(p.retard_sec AS FLOAT))
                                OVER (PARTITION BY p.line_id, p.direction_id, p.ordre_geo, p.stop_id_racine),
            ecart_type_sec    = STDEV(CAST(p.retard_sec AS FLOAT))
                                OVER (PARTITION BY p.line_id, p.direction_id, p.ordre_geo, p.stop_id_racine)
    FROM    #passage AS p
)
SELECT      line_id,
            route_type,
            direction_id,
            ordre_geo,
            stop_name,
            libelle_affichage,
            stop_id_racine,
            n_passages,
            retard_median_sec = CAST(retard_median_sec AS DECIMAL(8,1)),
            retard_p10_sec    = CAST(retard_p10_sec    AS DECIMAL(8,1)),
            retard_p90_sec    = CAST(retard_p90_sec    AS DECIMAL(8,1)),
            retard_moyen_sec  = CAST(retard_moyen_sec  AS DECIMAL(8,1)),
            ecart_type_sec    = CAST(ecart_type_sec    AS DECIMAL(8,1))
INTO        dbo.int_profil_arret
FROM        par_arret;
GO


/*=============================================================================
  3. int_segment - VISUELS 2 ET 3
  ----------------------------------------------------------------------------
  Pour chaque course et chaque jour, on suit le vehicule d'arret en
  arret dans l'ORDRE DE PASSAGE PREVU, et on mesure ce que le retard
  gagne ou perd entre deux arrets consecutifs.

  delta > 0  : le vehicule PERD du temps sur ce troncon
  delta < 0  : il en regagne (ou l'horaire y est genereux)

  AUCUN FILTRE D'ADJACENCE NUMERIQUE (voir l'en-tete) : la partition
  par course et par jour garantit deja que deux lignes successives
  sont deux arrets successifs du meme vehicule.

  Le seul risque residuel est le TROU : si un passage intermediaire
  n'a pas ete apparie, le segment enjambe un arret sans le dire. On
  ne le supprime pas - on le REND VISIBLE via saut_de_rang, et le
  controle H1c le chiffre. Marquer plutot que supprimer : meme
  principe que est_observable.
=============================================================================*/

DROP TABLE IF EXISTS dbo.int_segment;

;WITH suite AS (
    SELECT      p.line_id,
                p.route_type,
                p.direction_id,
                p.ordre_geo,
                p.libelle_affichage,
                p.stop_id_racine,
                ordre_prec  = LAG(p.ordre_geo)         OVER (PARTITION BY p.course_sk, p.date_sk
                                                             ORDER BY p.theorique_sec),
                nom_prec    = LAG(p.libelle_affichage) OVER (PARTITION BY p.course_sk, p.date_sk
                                                             ORDER BY p.theorique_sec),
                racine_prec = LAG(p.stop_id_racine)    OVER (PARTITION BY p.course_sk, p.date_sk
                                                             ORDER BY p.theorique_sec),
                duree_theo_sec = p.theorique_sec - LAG(p.theorique_sec)
                                 OVER (PARTITION BY p.course_sk, p.date_sk
                                       ORDER BY p.theorique_sec),
                delta_sec   = p.retard_sec - LAG(p.retard_sec)
                              OVER (PARTITION BY p.course_sk, p.date_sk
                                    ORDER BY p.theorique_sec)
    FROM        #passage AS p
),
adjacents AS (
    SELECT      s.*,
                saut_de_rang = ABS(s.ordre_geo - s.ordre_prec)
    FROM        suite AS s
    WHERE       s.delta_sec IS NOT NULL
      AND       NOT EXISTS (
                    -- Un arret existe-t-il STRICTEMENT ENTRE les deux ?
                    -- Si oui, le segment enjambe un trou d'appariement.
                    SELECT 1
                    FROM   dbo.int_profil_arret AS x
                    WHERE  x.line_id      = s.line_id
                      AND  x.direction_id = s.direction_id
                      AND  x.ordre_geo > CASE WHEN s.ordre_geo < s.ordre_prec
                                              THEN s.ordre_geo ELSE s.ordre_prec END
                      AND  x.ordre_geo < CASE WHEN s.ordre_geo < s.ordre_prec
                                              THEN s.ordre_prec ELSE s.ordre_geo END)
),
agrege AS (
    /*------------------------------------------------------------------------
      ⚠️ LA CLE D'AGREGATION EST LE COUPLE D'ARRETS, PAS L'ARRIVEE.

      Premiere version : PARTITION BY (line_id, direction_id, ordre_geo),
      donc sur le seul arret d'ARRIVEE. Sur la ligne 25 cela marchait
      par accident - chaque arret n'y a qu'un seul predecesseur possible.

      Au reseau, c'est faux. Une ligne a variantes de trace fait
      converger PLUSIEURS predecesseurs vers un meme arret d'arrivee.
      Le SELECT DISTINCT produisait alors une ligne par predecesseur,
      toutes porteuses des MEMES agregats. Mesure du 03/09 : la ligne
      50 direction 0 sortait huit fois "-> PIERRE DECOSTER", chacune
      avec 986 courses et +19 s. Total reseau : 11 709 segments pour
      ~3 220 attendus, soit 3,6 fois trop.

      Ce defaut existait DEJA ; le filtre ABS(diff) = 10 le masquait en
      ne laissant passer qu'un predecesseur par arrivee. En retirant le
      filtre, on a revele le bug au lieu de le creer.

      Un segment est une PAIRE : il se partitionne comme une paire.
      Meme principe que le grain de fact_ecart - la cle doit decrire
      ce qu'UNE LIGNE represente.

      ordre_geo devient un ATTRIBUT du segment (celui de l'arrivee),
      plus une composante de sa cle : d'ou le MIN() OVER.
    ------------------------------------------------------------------------*/
    SELECT DISTINCT
            a.line_id,
            a.route_type,
            a.direction_id,
            segment        = a.nom_prec + ' -> ' + a.libelle_affichage,
            racine_debut   = a.racine_prec,
            racine_fin     = a.stop_id_racine,
            ordre_geo      = MIN(a.ordre_geo) OVER (PARTITION BY a.line_id, a.direction_id,
                                                                 a.racine_prec, a.stop_id_racine),
            n_courses      = COUNT(*) OVER (PARTITION BY a.line_id, a.direction_id,
                                                         a.racine_prec, a.stop_id_racine),
            saut_de_rang   = MIN(a.saut_de_rang) OVER (PARTITION BY a.line_id, a.direction_id,
                                                                    a.racine_prec, a.stop_id_racine),
            duree_theo_sec = AVG(CAST(a.duree_theo_sec AS FLOAT))
                             OVER (PARTITION BY a.line_id, a.direction_id,
                                                a.racine_prec, a.stop_id_racine),
            delta_median   = PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY a.delta_sec)
                             OVER (PARTITION BY a.line_id, a.direction_id,
                                                a.racine_prec, a.stop_id_racine),
            delta_moyen    = AVG(CAST(a.delta_sec AS FLOAT))
                             OVER (PARTITION BY a.line_id, a.direction_id,
                                                a.racine_prec, a.stop_id_racine),
            ecart_type     = STDEV(CAST(a.delta_sec AS FLOAT))
                             OVER (PARTITION BY a.line_id, a.direction_id,
                                                a.racine_prec, a.stop_id_racine)
    FROM    adjacents AS a
    WHERE   a.racine_prec IS NOT NULL
)
SELECT      line_id,
            route_type,
            direction_id,
            ordre_geo,
            segment,
            racine_debut,
            racine_fin,
            n_courses,
            saut_de_rang,
            duree_theo_sec = CAST(duree_theo_sec AS DECIMAL(8,1)),
            delta_median   = CAST(delta_median   AS DECIMAL(8,1)),
            delta_moyen    = CAST(delta_moyen    AS DECIMAL(8,1)),
            ecart_type     = CAST(ecart_type     AS DECIMAL(8,1))
INTO        dbo.int_segment
FROM        agrege;
GO


/*=============================================================================
  CONTROLES
=============================================================================*/

PRINT '=== H1 - Volumetrie ===';
-- La ligne 25 compte 51 points observes et 2 directions.
-- Attendu : ~100 lignes de profil, ~95 segments (un de moins par
-- direction, le premier arret n'ayant pas de predecesseur).
SELECT  profil_arrets = (SELECT COUNT(*) FROM dbo.int_profil_arret),
        segments      = (SELECT COUNT(*) FROM dbo.int_segment),
        lignes        = (SELECT COUNT(DISTINCT line_id) FROM dbo.int_segment);
GO


PRINT '=== H1b - DIAGNOSTIC D ADJACENCE (indispensable en mode reseau) ===';
/*----------------------------------------------------------------------------
  Ce controle chiffre les segments MANQUANTS par ligne et direction.

  HISTORIQUE - une hypothese posee puis refutee par la mesure :
  la premiere version exigeait ABS(ordre_geo - ordre_prec) = 10 pour
  declarer deux arrets consecutifs, et la perte constatee (145
  segments) etait attribuee aux LIGNES A BRANCHES (reserve B2 :
  87, 4, 1, 51, 93). La mesure a refute cette explication : la 93 ne
  perdait rien, la 4 et la 51 perdaient autant que la moyenne, et les
  pertes se concentraient sur 95, 38, 50, 61 - qui n'ont pas de
  branche. La vraie cause etait le PAS DE NUMEROTATION variable.
  La reserve B2 tombe : elle designait un coupable innocent.

  ⚠️ NE PAS RAISONNER EN RATIO. Le nombre attendu est arrets - 1 :
     le premier arret n'a pas de predecesseur. Le ratio maximal
     atteignable vaut donc (n-1)/n, qui DEPEND DE LA TAILLE de la
     ligne. Une ligne de 6 arrets plafonne a 0,83 sans rien avoir
     perdu, alors qu'une ligne de 29 arrets a 0,83 en a perdu 4.
     Un premier controle ecrit en ratio a fait croire a un probleme
     de branches sur la 35 et innocente la 95, exactement a
     l'inverse de la realite.
     -> L'indicateur est la PERTE ABSOLUE : arrets - segments - 1.

  Attendu apres les deux corrections du 03/09 (pas de numerotation,
  puis cle d'agregation) : proche de 0. Une valeur NEGATIVE signale
  des doublons - la cle d'agregation a de nouveau derape. Une valeur
  POSITIVE designe un trou d'appariement, ce qui est normal a la
  marge.

  ⚠️ NON-REGRESSION : la ligne 25 n'a pas de variante de trace. Elle
     DOIT redonner 24 et 25 segments, et H2 doit retrouver +24 s
     dans les deux sens. C'est le test de cette correction.
----------------------------------------------------------------------------*/
SELECT      s.line_id, s.direction_id,
            arrets   = MAX(a.n_arrets),
            segments = COUNT(*),
            perdus   = MAX(a.n_arrets) - COUNT(*) - 1
FROM        dbo.int_segment AS s
CROSS APPLY (SELECT n_arrets = COUNT(*)
             FROM   dbo.int_profil_arret AS p
             WHERE  p.line_id     = s.line_id
               AND  p.direction_id = s.direction_id) AS a
GROUP BY    s.line_id, s.direction_id
HAVING      MAX(a.n_arrets) - COUNT(*) - 1 <> 0
ORDER BY    perdus DESC, s.line_id;
GO


PRINT '=== H1c - Segments qui enjambent un arret ===';
-- saut_de_rang est l'ecart de rang entre les deux arrets du segment.
-- Sa valeur NORMALE varie selon la ligne (10 sur la 25, 1 a 10 sur
-- la 95) : ce qui compte n'est pas la valeur mais sa STABILITE au
-- sein d'une meme ligne. Un segment dont le saut vaut plusieurs fois
-- le pas courant de sa ligne enjambe probablement un arret non
-- apparie. A connaitre avant de commenter un troncon.
-- ⚠️ Pas de seuil absolu : le pas courant varie selon la ligne (10
--    sur la 25, 1 a 10 sur la 95). On compare chaque segment au pas
--    MEDIAN de sa propre ligne.
;WITH pas_de_ligne AS (
    SELECT DISTINCT
            line_id,
            direction_id,
            pas_median = PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY saut_de_rang)
                         OVER (PARTITION BY line_id, direction_id)
    FROM    dbo.int_segment
)
SELECT      s.line_id, s.direction_id, s.segment,
            s.saut_de_rang, p.pas_median,
            rapport = CAST(1.0 * s.saut_de_rang / NULLIF(p.pas_median, 0) AS DECIMAL(6,2)),
            s.n_courses, s.delta_median
FROM        dbo.int_segment AS s
INNER JOIN  pas_de_ligne    AS p ON p.line_id     = s.line_id
                                AND p.direction_id = s.direction_id
WHERE       s.saut_de_rang > 2 * p.pas_median
ORDER BY    rapport DESC, s.n_courses DESC;
GO


PRINT '=== H2 - NON-REGRESSION : PATRIE <-> MEISER doit valoir +24 s ===';
-- Le controle qui relie cette table au resultat du 27/08.
-- ⚠️ Si le signe est negatif dans une direction, l'ordre de parcours
--    est faux : verifier que le LAG ordonne bien par theorique_sec.
SELECT      direction_id, ordre_geo, segment, n_courses,
            delta_median, delta_moyen, ecart_type
FROM        dbo.int_segment
WHERE       line_id = '25'
  AND      (segment LIKE '%PATRIE%' OR segment LIKE '%MEISER%')
ORDER BY    direction_id, ordre_geo;
GO


PRINT '=== H3 - LA QUESTION DE Q3 : l ecart-type est-il uniforme ? ===';
/*----------------------------------------------------------------------------
  C'EST LE CONTROLE QUI DECIDE DE LA CONCLUSION.

  Si les ecarts-types sont HOMOGENES le long de la ligne alors que
  les medianes varient fortement, cela signifie que la variabilite
  d'exploitation est la meme partout : ce qui distingue un troncon,
  c'est un DECALAGE SYSTEMATIQUE, donc un temps de parcours theorique
  mal calibre. -> probleme d'HORAIRE.

  Si au contraire les ecarts-types explosent sur les memes troncons
  que les medianes, c'est de l'IRREGULARITE : le troncon est parfois
  fluide, parfois bloque. -> probleme de FIABILITE.

  Les deux conclusions menent a des recommandations OPPOSEES.
  Ne pas rediger la slide avant d'avoir lu ce tableau.
----------------------------------------------------------------------------*/
SELECT      direction_id,
            n_segments      = COUNT(*),
            median_min      = MIN(delta_median),
            median_max      = MAX(delta_median),
            median_amplitude= MAX(delta_median) - MIN(delta_median),
            ec_type_min     = MIN(ecart_type),
            ec_type_max     = MAX(ecart_type),
            ec_type_moyen   = CAST(AVG(ecart_type) AS DECIMAL(8,1)),
            ec_type_de_l_ecart_type = CAST(STDEV(ecart_type) AS DECIMAL(8,1))
FROM        dbo.int_segment
WHERE       line_id = '25'
GROUP BY    direction_id;
GO


PRINT '=== H4 - Les 10 segments les plus couteux ===';
-- La matiere de la recommandation finale.
-- duree_theo_sec permet de relativiser : +24 s sur un troncon prevu
-- pour 60 s n'a pas le meme sens que sur un troncon prevu pour 300 s.
SELECT TOP 15
            line_id, direction_id, segment, n_courses, saut_de_rang,
            duree_theo_sec, delta_median, ecart_type,
            pct_du_temps_prevu = CAST(100.0 * delta_median
                                      / NULLIF(duree_theo_sec, 0) AS DECIMAL(6,1))
FROM        dbo.int_segment
WHERE       n_courses >= 200      -- ecarter les segments trop peu observes
  AND       racine_debut <> racine_fin
  -- ⚠️ Le 03/09, la ligne 96 a produit "PORTE DE HAL -> PORTE DE HAL"
  --    sur 554 courses : deux racines distinctes portant le meme
  --    libelle, ou une boucle de terminus. Non instruit, donc exclu
  --    du classement publie.
ORDER BY    delta_median DESC;
GO


PRINT '=== H5 - Profil complet, direction 0 (visuel 1) ===';
SELECT      ordre_geo, libelle_affichage, n_passages,
            retard_median_sec, retard_p10_sec, retard_p90_sec, ecart_type_sec
FROM        dbo.int_profil_arret
WHERE       line_id = '25' AND direction_id = 0
ORDER BY    ordre_geo;
GO
