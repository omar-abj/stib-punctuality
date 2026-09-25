/*=============================================================================
  TFE STIB - 90_checks/94_decomposition_kpi.sql
  ----------------------------------------------------------------------------
  OBJET : repondre a la question que le jury posera en premier -
          "votre taux de conformite est de 65 %, qu'est-ce qu'il y a
           dans les 35 % restants ?"

  Un taux sans sa decomposition n'est pas un resultat (piege n°51).

  DEUX VERSIONS, A COMPARER AVANT DE CHOISIR :
    PARTIE A - la cascade, 4 postes. Calcul direct sur fact_ecart,
               quelques secondes. Additive, se lit sur une slide.
    PARTIE B - le diagnostic des non-apparies, 4 causes. Retourne
               dans wrk_passages pour savoir POURQUOI aucun reel
               n'a ete trouve. Plus lourd, plus profond.

  Les deux s'emboitent : le poste "non apparie" de A est exactement
  la population que B decompose.

  ⚠️ REMPLACE la decomposition du 27/08 (§19.A), calculee sur la
     ligne 25, a T = 240 s, et AVANT est_observable. Elle n'est plus
     valide : ni le perimetre, ni la tolerance, ni le denominateur
     ne sont les memes.

  Reference d'entree (passe A, 44 jours - HISTORIQUE, perimetre soutenance) :
      theoriques bruts    3 030 537
      inobservables         146 141   (4,82 %)
      theoriques retenus  2 884 396   <- LE DENOMINATEUR
      apparies            2 558 115   (88,69 %)
      conformes           ~1 876 000  (65,06 %)
      non apparies          326 281   (11,31 %)

  Reference 52 jours (19/09/2026, apres rejeu complet) :
      theoriques bruts    3 602 475
      theoriques retenus  3 428 704   <- LE DENOMINATEUR
      apparies            3 012 361   (87,86 %)
      conformes           2 216 461   (64,64 %)
      non apparies          416 343   (12,14 %)
=============================================================================*/

USE TFE_STIB;
GO

SET NOCOUNT ON;


/*=============================================================================
  PARTIE A - LA CASCADE
  ----------------------------------------------------------------------------
  Quatre postes qui font 100 % du theorique retenu :

    1. conforme            passe dans la fenetre -60 / +180 s
    2. apparie, en avance  retrouve, mais plus de 60 s trop tot
    3. apparie, en retard  retrouve, mais plus de 180 s trop tard
    4. non apparie         aucun partenaire trouve (voir PARTIE B)

  L'interet de cette lecture : elle separe ce qui est un DEFAUT DE
  SERVICE MESURE (postes 2 et 3) de ce qui est une ABSENCE DE MESURE
  (poste 4). Deux choses qu'un taux global confond.

  ⚠️ L'avance est un vrai probleme d'exploitation, pas un bonus :
     un vehicule en avance fait rater son passage aux voyageurs
     presents a l'heure. D'ou la fenetre asymetrique -60 / +180.
=============================================================================*/

PRINT '=== A1 - Cascade sur le theorique retenu ===';

SELECT      poste = CASE
                WHEN f.nb_theorique = 0                       THEN '0_hors_denominateur'
                WHEN f.nb_conforme  = 1                       THEN '1_conforme'
                WHEN f.nb_apparie   = 1 AND f.retard_sec < -60  THEN '2_apparie_en_avance'
                WHEN f.nb_apparie   = 1 AND f.retard_sec > 180  THEN '3_apparie_en_retard'
                WHEN f.nb_theo_seul = 1                       THEN '4_non_apparie'
                ELSE '9_inclassable'
            END,
            passages = COUNT(*),
            pct      = CAST(100.0 * COUNT(*)
                            / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))
FROM        dbo.fact_ecart AS f
WHERE       f.nb_theorique = 1
GROUP BY    CASE
                WHEN f.nb_theorique = 0                       THEN '0_hors_denominateur'
                WHEN f.nb_conforme  = 1                       THEN '1_conforme'
                WHEN f.nb_apparie   = 1 AND f.retard_sec < -60  THEN '2_apparie_en_avance'
                WHEN f.nb_apparie   = 1 AND f.retard_sec > 180  THEN '3_apparie_en_retard'
                WHEN f.nb_theo_seul = 1                       THEN '4_non_apparie'
                ELSE '9_inclassable'
            END
ORDER BY    1;
GO
-- '9_inclassable' DOIT valoir 0. Toute autre valeur signale un cas
-- non prevu par la cascade : l'instruire avant de publier.


PRINT '=== A2 - La meme cascade, par mode (prepare Q2) ===';
SELECT      l.route_type,
            poste = CASE
                WHEN f.nb_conforme  = 1                       THEN '1_conforme'
                WHEN f.nb_apparie   = 1 AND f.retard_sec < -60  THEN '2_apparie_en_avance'
                WHEN f.nb_apparie   = 1 AND f.retard_sec > 180  THEN '3_apparie_en_retard'
                ELSE '4_non_apparie' END,
            passages = COUNT(*),
            pct_du_mode = CAST(100.0 * COUNT(*)
                               / SUM(COUNT(*)) OVER (PARTITION BY l.route_type) AS DECIMAL(5,2))
FROM        dbo.fact_ecart AS f
INNER JOIN  dbo.dim_ligne  AS l ON l.ligne_sk = f.ligne_sk
WHERE       f.nb_theorique = 1
GROUP BY    l.route_type,
            CASE
                WHEN f.nb_conforme  = 1                       THEN '1_conforme'
                WHEN f.nb_apparie   = 1 AND f.retard_sec < -60  THEN '2_apparie_en_avance'
                WHEN f.nb_apparie   = 1 AND f.retard_sec > 180  THEN '3_apparie_en_retard'
                ELSE '4_non_apparie' END
ORDER BY    l.route_type, poste;
GO


PRINT '=== A3 - Le cout du marquage est_observable ===';
-- A remonter d'un cran : ce qui a ete retire AVANT le denominateur.
-- Sans ce marquage, 146 141 passages qui ne peuvent PAS etre
-- observes seraient comptes comme des defauts de service.
SELECT      motif = ISNULL(motif_inobservable, '0_retenu_au_denominateur'),
            passages = COUNT(*),
            pct = CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))
FROM        dbo.int_passage_theorique
GROUP BY    ISNULL(motif_inobservable, '0_retenu_au_denominateur')
ORDER BY    motif;
GO


/*=============================================================================
  PARTIE B - POURQUOI 326 281 PASSAGES N'ONT-ILS PAS DE PARTENAIRE ?
  ----------------------------------------------------------------------------
  On retourne dans wrk_passages, AVANT tout filtre, pour chercher ce
  qui existait en face de chaque theorique non apparie.

  Quatre causes, exclusives, de la plus "mesure" a la plus "service" :

  1_aucun_passage_du_jour  Aucun passage reel de ce triplet ce jour,
                           a aucune heure. Trou de collecte, ou
                           desserte non assuree ce jour-la.
                           -> defaut de MESURE (ou de service massif)

  2_ecarte_par_les_filtres Un reel existait dans la tolerance, mais
                           il a ete ecarte par nb_obs >= 2 ou par la
                           fraicheur. C'est NOTRE filtre qui cree le
                           non-appariement.
                           -> defaut de MESURE, imputable a la methode

  3_concurrence            Un reel valide existait dans la tolerance,
                           mais il a ete apparie a un AUTRE theorique.
                           Limite de l'algorithme un-a-un.
                           -> defaut de MESURE, imputable a l'algorithme

  4_aucun_reel_a_portee    Des passages ont eu lieu ce jour, mais
                           aucun dans la fenetre de tolerance.
                           -> defaut de SERVICE (course supprimee,
                              ou retard hors limite d'identifiabilite)

  ⚠️ LIMITE A ENONCER : la cause 4 melange "course supprimee" et
     "course tellement en retard qu'elle sort de la tolerance". Sans
     trip_id, ces deux hypotheses produisent une observation
     IDENTIQUE (§19.C). Aucune methode ne les separe : l'information
     n'est pas dans les donnees.

  ⚠️ COUT : ~326 000 lignes croisees a wrk_passages (3,9 M). Compter
     quelques minutes.
=============================================================================*/

PRINT '=== B1 - Diagnostic des non-apparies ===';

DROP TABLE IF EXISTS #theo_orphelin;

SELECT      i.appariement_id,
            i.date_service,
            i.feed_version,
            i.line_id,
            i.point_id,
            i.trip_headsign,
            i.passage_theorique,
            i.tolerance_sec
INTO        #theo_orphelin
FROM        dbo.int_appariement AS i
WHERE       i.statut_appariement = 'theorique_non_apparie';

CREATE CLUSTERED INDEX ix_orph
    ON #theo_orphelin (line_id, point_id, date_service, passage_theorique);
GO

;WITH candidats AS (
    -- Tous les passages REELS BRUTS du meme triplet, le meme jour,
    -- sans aucun filtre de qualite ni de fenetre.
    SELECT      o.appariement_id,
                p.nb_obs,
                fraicheur_sec = DATEDIFF(SECOND, p.derniere_obs, p.arrivee_estimee),
                ecart_sec     = ABS(DATEDIFF(SECOND, o.passage_theorique, p.arrivee_estimee)),
                o.tolerance_sec
    FROM        #theo_orphelin AS o
    INNER JOIN  dbo.ref_feed_periode AS f
            ON  o.date_service BETWEEN f.date_debut AND f.date_fin
    INNER JOIN  dbo.map_destination AS m
            ON  m.feed_version   = f.feed_version
           AND  m.line_id        = o.line_id       COLLATE DATABASE_DEFAULT
           AND  m.trip_headsign  = o.trip_headsign COLLATE DATABASE_DEFAULT
           AND  m.type_mapping IN ('exact', 'devie', 'abrege')
    INNER JOIN  dbo.wrk_passages AS p
            ON  p.line_id     = o.line_id COLLATE DATABASE_DEFAULT
           AND  p.point_id    = o.point_id COLLATE DATABASE_DEFAULT
           AND  p.destination = m.destination_rt
           AND  CAST(p.derniere_obs AS DATE) = o.date_service
),
bilan AS (
    SELECT      o.appariement_id,
                n_du_jour      = COUNT(c.appariement_id),
                n_dans_tol     = SUM(CASE WHEN c.ecart_sec <= c.tolerance_sec
                                          THEN 1 ELSE 0 END),
                n_valide_tol   = SUM(CASE WHEN c.ecart_sec <= c.tolerance_sec
                                           AND c.nb_obs >= 2
                                           AND c.fraicheur_sec BETWEEN -120 AND 180
                                          THEN 1 ELSE 0 END)
    FROM        #theo_orphelin AS o
    LEFT  JOIN  candidats      AS c ON c.appariement_id = o.appariement_id
    GROUP BY    o.appariement_id
)
SELECT      cause = CASE
                WHEN b.n_du_jour    = 0 THEN '1_aucun_passage_du_jour'
                WHEN b.n_dans_tol   = 0 THEN '4_aucun_reel_a_portee'
                WHEN b.n_valide_tol = 0 THEN '2_ecarte_par_les_filtres'
                ELSE                         '3_concurrence'
            END,
            passages = COUNT(*),
            pct_des_non_apparies = CAST(100.0 * COUNT(*)
                                        / SUM(COUNT(*)) OVER () AS DECIMAL(5,2)),
            pct_du_theorique     = CAST(100.0 * COUNT(*)
                                        / (SELECT SUM(CAST(nb_theorique AS BIGINT)) FROM dbo.fact_ecart)
                                        AS DECIMAL(5,2))
FROM        bilan AS b
GROUP BY    CASE
                WHEN b.n_du_jour    = 0 THEN '1_aucun_passage_du_jour'
                WHEN b.n_dans_tol   = 0 THEN '4_aucun_reel_a_portee'
                WHEN b.n_valide_tol = 0 THEN '2_ecarte_par_les_filtres'
                ELSE                         '3_concurrence'
            END
ORDER BY    cause;
GO
-- Le total DOIT valoir SUM(nb_theo_seul) de fact_ecart (326 281 a 44 jours,
-- 416 343 a 52 jours). Le denominateur de pct_du_theorique est lu dans
-- fact_ecart depuis le 19/09 : il etait ecrit en dur (2 884 396, 44 jours)
-- et donnait des pourcentages faux, sans erreur, des que le perimetre changeait.
