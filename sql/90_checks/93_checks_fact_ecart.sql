/*=============================================================================
  TFE STIB - 90_checks/93_checks_fact_ecart.sql
  ----------------------------------------------------------------------------
  A lancer APRES 60_fact_ecart.sql.

  CE QUE CES CONTROLES VERIFIENT, ET CE QU'ILS NE VERIFIENT PAS
  ----------------------------------------------------------------------------
  Ils ne disent pas si 64,64 % est la "vraie" ponctualite : ce chiffre
  depend de choix (fenetre, tolerance, filtres). Ils verifient que la
  chaine applique CORRECTEMENT ces choix. Trois familles :
    INVARIANTS        vrais par construction, quels que soient les choix
                      (G1, G2, G4 course, G6, G7, G9). Un echec = un bug.
    REPRODUCTIBILITE  memes donnees + memes choix = memes chiffres
                      (G3, G3b, G3c, G4, G5, G8). Un ecart = quelque chose
                      a change dans les donnees ou dans un script.
    PHOTOGRAPHIE      G10, a conserver d'un rejeu a l'autre.

  REECRIT LE 03/09 - l'ancienne version portait les valeurs de la
  ligne 25 a T = 240 s. Elle signalait des echecs partout alors que
  tout allait bien. Un controle dont les cibles sont perimees est
  pire qu'aucun controle : il apprend a ignorer les alertes.

  ----------------------------------------------------------------------------
  VALEURS DE REFERENCE - PASSE B, 52 jours (1er juillet -> 26 aout 2026)
  == REFERENCE ACTUELLE ==
  ----------------------------------------------------------------------------
  Mesurees le 26/09/2026. Tous les invariants passent.

      fact_ecart                 3 667 714
      nb_theorique               3 428 704
      nb_reel                    3 251 371
      nb_apparie                 3 012 361
      nb_theo_seul                 416 343
      nb_reel_seul                 239 010
      taux d'appariement             87,86 %   <- passages RETROUVES
      taux de conformite             64,64 %   <- passages A L'HEURE
      ligne 25 : appariement         95,61 %
      ligne 25 : conformite          65,00 %
      course_sk = -1               239 010   (= les reels seuls)
      desserte_sk = -1              49 958
      meteo_sk = -1                      0   (aout recharge)
      retard_sec                   -300 / +300
      PATRIE <-> MEISER              +24 s (dir. 0) / +22 s (dir. 1)

  ----------------------------------------------------------------------------
  VALEURS DE REFERENCE - PASSE A, 44 jours (1er juillet -> 18 aout 2026)
  == HISTORIQUE, conservees pour comparaison ==
  ----------------------------------------------------------------------------
  Mesurees le 03/09 sur ce rejeu, coherentes avec le 27/08 a 484
  lignes pres (voir G0 ci-dessous).

      fact_ecart                 3 077 750
      nb_theorique               2 884 396
      nb_reel                    2 751 469
      nb_apparie                 2 558 115
      nb_theo_seul                 326 281
      nb_reel_seul                 193 354
      taux d'appariement             88,69 %   <- passages RETROUVES
      taux de conformite             65,06 %   <- passages A L'HEURE
      ligne 25 : appariement         95,86 %
      ligne 25 : conformite          64,40 %
      course_sk = -1               193 354   (= les reels seuls)
      desserte_sk = -1              41 830
      meteo_sk = -1              1 225 665   (aout non collecte)
      retard_sec                   -300 / +300
      PATRIE <-> MEISER              +24 s dans les deux sens

  ----------------------------------------------------------------------------
  ⚠️ NE JAMAIS CONFONDRE CES DEUX TAUX
  ----------------------------------------------------------------------------
  APPARIEMENT  = SUM(nb_apparie)  / SUM(nb_theorique)
      "le passage annonce a-t-il ete RETROUVE dans le flux ?"
      Mesure de COUVERTURE : la part du theorique sur laquelle un
      differentiel de retard est calculable. Reseau 87,86 %.

  CONFORMITE   = SUM(nb_conforme) / SUM(nb_theorique)
      "le passage a-t-il eu lieu DANS LA FENETRE -60/+180 s ?"
      LE KPI DU MEMOIRE. Un passage non apparie y est non conforme,
      au meme titre qu'un apparie hors fenetre. Reseau 64,64 %.

  L'ecart entre les deux (ligne 25 : 95,61 % contre 65,00 %) est
  constitue des passages RETROUVES mais HORS FENETRE. Il ne signale
  aucune anomalie : ce sont deux questions differentes.

  ⚠️ Toujours nommer l'indicateur : "95,61 %" seul ne dit pas s'il
     s'agit de l'appariement ou de la conformite.

  COMPARAISON DES DEUX PASSES : le KPI reseau passe de 65,06 % a
  64,64 % (-0,42 pt) en ajoutant 8 jours d'aout. Le resultat spatial
  PATRIE <-> MEISER tient (+24 / +22 s contre +24 / +24 s).
=============================================================================*/

USE TFE_STIB;
GO

SET NOCOUNT ON;


/*=============================================================================
  G0 - L'ECART CONNU ET SON ORIGINE
  ----------------------------------------------------------------------------
  Le rejeu du 03/09 donne 3 077 750 lignes contre 3 077 266 le 27/08.
  Ecart : +484, soit 0,016 %.

  CAUSE TRACEE : 44_ref_tolerance_ligne.sql utilise
  APPROX_PERCENTILE_CONT, fonction APPROCHEE (piege n°58). Sur la
  ligne 71, le P10 est ressorti a 386 s au lieu de 410 s, faisant
  passer sa tolerance de 205 a 193 s. Une fenetre plus etroite forme
  moins de couples ; chaque couple non forme libere UN theorique et
  UN reel, d'ou +484 des deux cotes et un dénominateur inchange.

  LECTURE POUR LA SOUTENANCE : un parametre de methode qui bouge de
  12 s sur 1 ligne sur 76 deplace le KPI reseau de 0,01 point. C'est
  une mesure de robustesse, pas un incident.

  CORRECTIF DE FOND A PREVOIR : PERCENTILE_CONT exact.
=============================================================================*/


PRINT '=== G1 - Conservation du volume ===';
-- Attendu : n_source = n_fait = 3 667 714  (passe A : 3 077 750).
-- ⚠️ L'ancienne version portait "WHERE line_id = NULL", toujours
--    faux en SQL : le controle renvoyait 0 quoi qu'il arrive
--    (piege n°23). Clause supprimee.
SELECT  n_source = (SELECT COUNT(*) FROM dbo.int_appariement),
        n_fait   = (SELECT COUNT(*) FROM dbo.fact_ecart);

SELECT      statut_appariement, n = COUNT(*)
FROM        dbo.fact_ecart
GROUP BY    statut_appariement
ORDER BY    COUNT(*) DESC;
GO


PRINT '=== G2 - Coherence des compteurs additifs ===';
-- Attendu : theorique 3 428 704 | reel 3 251 371 | apparie 3 012 361
--           theo_seul 416 343   | reel_seul 239 010
-- (passe A : 2 884 396 | 2 751 469 | 2 558 115 | 326 281 | 193 354)
-- Les deux recoupements DOIVENT tomber :
--   apparie + theo_seul = theorique
--   apparie + reel_seul = reel
SELECT  theorique      = SUM(CAST(nb_theorique AS INT)),
        reel           = SUM(CAST(nb_reel      AS INT)),
        apparie        = SUM(CAST(nb_apparie   AS INT)),
        theo_seul      = SUM(CAST(nb_theo_seul AS INT)),
        reel_seul      = SUM(CAST(nb_reel_seul AS INT)),
        ctrl_theorique = SUM(CAST(nb_apparie AS INT)) + SUM(CAST(nb_theo_seul AS INT)),
        ctrl_reel      = SUM(CAST(nb_apparie AS INT)) + SUM(CAST(nb_reel_seul AS INT))
FROM    dbo.fact_ecart;
GO


PRINT '=== G3 - Taux, recalcules depuis la table de faits ===';
-- Attendu : appariement 87,86 % | non-appariement 12,14 % | ajout 7,35 %
-- (passe A : 88,69 % | 11,31 % | 7,03 %)
--
-- ⚠️ VOCABULAIRE : "taux de non-appariement", JAMAIS "taux de
--    suppression" (§19.A). C'est un indicateur COMPOSITE dont la
--    decomposition est chiffree : ~2,84 pts de service et ~2,49 pts
--    de mesure sur la ligne 25. L'appeler suppression attribuerait
--    a la STIB des defauts qui sont les notres.
SELECT  taux_appariement     = CAST(100.0 * SUM(CAST(nb_apparie   AS INT))
                                    / NULLIF(SUM(CAST(nb_theorique AS INT)), 0) AS DECIMAL(5,2)),
        taux_non_appariement = CAST(100.0 * SUM(CAST(nb_theo_seul AS INT))
                                    / NULLIF(SUM(CAST(nb_theorique AS INT)), 0) AS DECIMAL(5,2)),
        taux_ajout           = CAST(100.0 * SUM(CAST(nb_reel_seul AS INT))
                                    / NULLIF(SUM(CAST(nb_reel      AS INT)), 0) AS DECIMAL(5,2))
FROM    dbo.fact_ecart;
GO


PRINT '=== G3b - LE KPI PRINCIPAL : taux de service conforme ===';
-- Attendu reseau : 64,64 %  |  ligne 25 : 65,00 %
-- (passe A : 65,06 % | 64,40 %)
-- ⚠️ NE PAS y attendre 87,86 % ni 95,61 % : ce sont les taux
--    d'APPARIEMENT (G3), une mesure de couverture, pas de qualite.
-- ABSENT de l'ancienne version alors que c'est LA mesure du memoire.
-- Fenetre -60 / +180 s (convention du projet), rapportee au THEORIQUE : un passage non
-- apparie est non conforme au meme titre qu'un apparie hors fenetre.
-- C'est ce qui rend les lignes comparables malgre un T variable.
SELECT  taux_conformite = CAST(100.0 * SUM(CAST(nb_conforme  AS INT))
                               / NULLIF(SUM(CAST(nb_theorique AS INT)), 0) AS DECIMAL(5,2))
FROM    dbo.fact_ecart;

-- Non-regression ligne 25 : DOIT valoir 65,00 % (conformite).
-- Son taux d'APPARIEMENT, lui, vaut 95,61 % - voir G3c.
SELECT  taux_conformite_ligne_25 = CAST(100.0 * SUM(CAST(f.nb_conforme  AS INT))
                                        / NULLIF(SUM(CAST(f.nb_theorique AS INT)), 0) AS DECIMAL(5,2))
FROM        dbo.fact_ecart AS f
INNER JOIN  dbo.dim_ligne  AS l ON l.ligne_sk = f.ligne_sk
WHERE       l.line_id = '25';
GO


PRINT '=== G3c - Non-regression : APPARIEMENT de la ligne 25 ===';
-- DOIT valoir 95,61 % (68 831 / 71 991). Passe A : 95,86 %
-- (58 037 / 60 541), le chiffre historique du 27/08. Il vit ICI,
-- pas dans G3b.
SELECT  theoriques   = SUM(CAST(f.nb_theorique AS INT)),
        apparies     = SUM(CAST(f.nb_apparie   AS INT)),
        taux_appariement_ligne_25 = CAST(100.0 * SUM(CAST(f.nb_apparie   AS INT))
                                         / NULLIF(SUM(CAST(f.nb_theorique AS INT)), 0) AS DECIMAL(5,2))
FROM        dbo.fact_ecart AS f
INNER JOIN  dbo.dim_ligne  AS l ON l.ligne_sk = f.ligne_sk
WHERE       l.line_id = '25';
GO


PRINT '=== G4 - Recours aux membres inconnus (-1) ===';
-- Les FK interdisent deja l'orphelin. Ce controle compte les cles
-- VALIDES mais NON RESOLUES, ce qui est une information differente.
-- Attendu :
--   heure / ligne / arret  = 0          (toute autre valeur = alerte)
--   course                 = 239 010    (les reels seuls, par construction)
--   desserte               =  49 958    ⚠️ RESERVE OUVERTE, non expliquee
--   meteo                  =       0    (aout recharge ; passe A : 1 225 665)
SELECT  heure_inconnue    = SUM(CASE WHEN heure_sk    = -1 THEN 1 ELSE 0 END),
        ligne_inconnue    = SUM(CASE WHEN ligne_sk    = -1 THEN 1 ELSE 0 END),
        arret_inconnu     = SUM(CASE WHEN arret_sk    = -1 THEN 1 ELSE 0 END),
        desserte_inconnue = SUM(CASE WHEN desserte_sk = -1 THEN 1 ELSE 0 END),
        course_inconnue   = SUM(CASE WHEN course_sk   = -1 THEN 1 ELSE 0 END),
        meteo_inconnue    = SUM(CASE WHEN meteo_sk    = -1 THEN 1 ELSE 0 END)
FROM    dbo.fact_ecart;

-- Controle lie : course_sk = -1 doit etre EXACTEMENT les reels seuls.
SELECT  course_inconnue_hors_reel_seul = COUNT(*)
FROM    dbo.fact_ecart
WHERE   course_sk = -1 AND statut_appariement <> 'reel_non_apparie';
GO


PRINT '=== G5 - Resolution du sens des reels non apparies ===';
-- Attendu : racine 183 604 | destination 52 441 | non resolu 2 965
-- (passe A : 147 031 | 43 476 | 2 847)
-- Le niveau 3 ne servait JAMAIS sur la ligne 25 ; il sert au reseau.
-- Les 2 965 non resolus alimentent desserte_sk = -1 (voir G4).
SELECT      methode_resolution, n = COUNT(*)
FROM        dbo.fact_ecart
WHERE       statut_appariement = 'reel_non_apparie'
GROUP BY    methode_resolution
ORDER BY    COUNT(*) DESC;
GO


PRINT '=== G6 - Fenetre analytique ===';
-- Attendu : 100 % des lignes en est_fenetre_analytique = 1.
-- Une ligne hors fenetre signifierait que 40 et 45 n'ont pas ete
-- lances avec les MEMES @sec_debut / @sec_fin (33300 / 49500).
SELECT      h.est_fenetre_analytique, n = COUNT(*)
FROM        dbo.fact_ecart AS f
INNER JOIN  dbo.dim_heure  AS h ON h.heure_sk = f.heure_sk
GROUP BY    h.est_fenetre_analytique;
GO


PRINT '=== G7 - Censure de retard_sec ===';
-- ⚠️ CORRIGE : l'ancienne version testait +/-240, valeur de l'epoque
--    ou T etait un scalaire. T est VARIABLE depuis le 27/08 (193 a
--    300 s selon la ligne). La borne globale est donc +/-300.
-- Attendu : min = -300, max = 300, et les deux compteurs a 0.
SELECT  retard_min = MIN(retard_sec),
        retard_max = MAX(retard_sec),
        apparies_sans_retard     = SUM(CASE WHEN retard_sec IS NULL
                                             AND statut_appariement = 'apparie'
                                            THEN 1 ELSE 0 END),
        non_apparies_avec_retard = SUM(CASE WHEN retard_sec IS NOT NULL
                                             AND statut_appariement <> 'apparie'
                                            THEN 1 ELSE 0 END)
FROM    dbo.fact_ecart;

-- Controle plus fin : chaque ligne respecte-t-elle SA propre borne ?
-- DOIT renvoyer 0. Un depassement signifierait que la tolerance
-- portee par int_appariement ne correspond pas a celle appliquee.
SELECT  hors_tolerance_propre = COUNT(*)
FROM    dbo.fact_ecart
WHERE   retard_sec IS NOT NULL
  AND   ABS(retard_sec) > tolerance_sec;
GO


PRINT '=== G8 - Non-regression spatiale : PATRIE <-> MEISER ===';
/*----------------------------------------------------------------------------
  DEUX CORRECTIONS PAR RAPPORT A L'ANCIENNE VERSION.

  1. ordre_geo AVANCE PAR PAS DE 10 depuis la reecriture du 27/08
     (170, 180, ...). La condition "= ordre_prec + 1" ne pouvait plus
     JAMAIS etre vraie : la requete renvoyait zero ligne, en silence.
     -> ABS(difference) = 10. Le ABS est necessaire car l'echelle
        DECROIT le long du parcours en direction 1.

  2. FILTRE SUR LA RACINE, PAS SUR stop_name. La ligne 25 possede
     DEUX arrets nommes MEISER par direction (racines 2242 et 2246,
     libelles MEISER et MEISER REYERS). Filtrer sur stop_name captait
     deux paires par sens et rendait le controle ambigu.
     Racines du troncon etudie : 2241 / 6258 (dir. 0)
                                 2242 / 6204 (dir. 1)

  3. AGREGATION PAR MEDIANE, jamais par moyenne : les distributions
     de delta sont asymetriques (§15). Et delta PAR COURSE, pas
     moyenne des retards par arret - ce sont deux populations
     differentes (piege n°52).

  ATTENDU : +24 s (dir. 0, 1 297 courses) et +22 s (dir. 1, 1 403
            courses). Passe A : +24 s dans les deux sens, ~1 102 et
            ~1 184 courses.
  Si ces chiffres bougent sans changement de periode, une jointure a
  change le sens des donnees.
----------------------------------------------------------------------------*/
;WITH passages AS (
    SELECT      f.course_sk, f.date_sk,
                d.direction_id, d.ordre_geo,
                d.stop_name, d.libelle_affichage, d.stop_id_racine,
                f.retard_sec
    FROM        dbo.fact_ecart   AS f
    INNER JOIN  dbo.dim_desserte AS d ON d.desserte_sk = f.desserte_sk
    WHERE       f.statut_appariement = 'apparie'
      AND       f.course_sk <> -1
      AND       d.line_id = '25'
      AND       d.stop_id_racine IN ('2241', '6258', '2242', '6204')
),
segments AS (
    SELECT      p.direction_id, p.ordre_geo, p.libelle_affichage,
                ordre_prec = LAG(p.ordre_geo) OVER (
                                 PARTITION BY p.course_sk, p.date_sk
                                 ORDER BY p.ordre_geo),
                nom_prec   = LAG(p.stop_name) OVER (
                                 PARTITION BY p.course_sk, p.date_sk
                                 ORDER BY p.ordre_geo),
                delta_sec  = p.retard_sec - LAG(p.retard_sec) OVER (
                                 PARTITION BY p.course_sk, p.date_sk
                                 ORDER BY p.ordre_geo)
    FROM        passages AS p
)
SELECT DISTINCT
        s.direction_id,
        s.ordre_geo,
        segment      = s.nom_prec + ' -> ' + s.libelle_affichage,
        n_courses    = COUNT(*) OVER (PARTITION BY s.direction_id, s.ordre_geo),
        delta_median = PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY s.delta_sec)
                       OVER (PARTITION BY s.direction_id, s.ordre_geo),
        delta_moyen  = AVG(CAST(s.delta_sec AS FLOAT))
                       OVER (PARTITION BY s.direction_id, s.ordre_geo),
        ecart_type   = STDEV(CAST(s.delta_sec AS FLOAT))
                       OVER (PARTITION BY s.direction_id, s.ordre_geo)
FROM    segments AS s
WHERE   s.delta_sec IS NOT NULL
  AND   ABS(s.ordre_geo - s.ordre_prec) = 10
ORDER BY s.direction_id, s.ordre_geo;
GO


PRINT '=== G9 - Perimetre temporel : les deux cotes concordent-ils ? ===';
/*----------------------------------------------------------------------------
  CONTROLE NOUVEAU. Le defaut corrige le 03/09 dans 41 et 45 etait
  que le cote reel n'etait borne par AUCUNE source de perimetre : il
  partait de wrk_passages, quand le cote theorique descendait de
  wrk_jours. Tant que les deux coincidaient, le defaut etait invisible.

  DOIT renvoyer 0 ligne : aucune date de fait ne peut etre absente
  de wrk_jours.
----------------------------------------------------------------------------*/
SELECT      date_sk_orphelin = f.date_sk, n = COUNT(*)
FROM        dbo.fact_ecart AS f
WHERE       NOT EXISTS (
                SELECT 1 FROM dbo.wrk_jours AS j
                WHERE CAST(CONVERT(CHAR(8), j.date_service, 112) AS INT) = f.date_sk)
GROUP BY    f.date_sk
ORDER BY    f.date_sk;

-- Et le compte de jours doit egaler celui de wrk_jours (52 ; 44 en passe A).
SELECT  jours_dans_le_fait = COUNT(DISTINCT date_sk) FROM dbo.fact_ecart;
SELECT  jours_dans_wrk_jours = COUNT(*)              FROM dbo.wrk_jours;
GO


PRINT '=== G10 - Classement des lignes par taux de conformite ===';
-- Pas un controle mais une PHOTOGRAPHIE, a conserver d'un rejeu a
-- l'autre. C'est la matiere de la question business "quelles lignes
-- produisent l'offre annoncee ?".
-- ⚠️ Classement publie : les lignes avec dim_ligne.dans_classement = 1
--    (regle de 62 : presence les 7 premiers ET les 7 derniers jours).
--    Exclues : M1, M5, T7, 35. La 69 est hors perimetre (absente ici).
--    La 72 (une course par heure) RESTE classee : ligne reguliere a
--    basse frequence, pas un service partiel.
-- ⚠️ CLASSER SUR LA CONFORMITE, pas sur l'appariement : ce dernier
--    mesure ce que la methode retrouve, pas ce que la STIB produit.
-- Lecture du 26/09 (52 jours) : le haut du classement est occupe par
--    le METRO (1 -> 90,52 % | 5 -> 89,41 % | 6 -> 83,54 % | 2 -> 82,45 %),
--    le bas presque exclusivement par le BUS. Matiere de Q1.
--    ⚠️ Association, PAS causalite : le site propre est un facteur
--    de confusion evident du mode.
SELECT      l.line_id,
            l.route_type,
            theoriques       = SUM(CAST(f.nb_theorique AS INT)),
            apparies         = SUM(CAST(f.nb_apparie   AS INT)),
            conformes        = SUM(CAST(f.nb_conforme  AS INT)),
            taux_appariement = CAST(100.0 * SUM(CAST(f.nb_apparie   AS INT))
                                    / NULLIF(SUM(CAST(f.nb_theorique AS INT)), 0) AS DECIMAL(5,2)),
            taux_conformite  = CAST(100.0 * SUM(CAST(f.nb_conforme  AS INT))
                                    / NULLIF(SUM(CAST(f.nb_theorique AS INT)), 0) AS DECIMAL(5,2))
FROM        dbo.fact_ecart AS f
INNER JOIN  dbo.dim_ligne  AS l ON l.ligne_sk = f.ligne_sk
GROUP BY    l.line_id, l.route_type
HAVING      SUM(CAST(f.nb_theorique AS INT)) > 0
ORDER BY    taux_conformite;
GO
