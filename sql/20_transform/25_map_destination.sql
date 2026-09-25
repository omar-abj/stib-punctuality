/*==============================================================================
  TFE STIB - 20_transform/25_map_destination.sql
  ----------------------------------------------------------------------------
  OBJET : Reconstruire integralement la table de correspondance entre la
          destination annoncee par l'API temps reel (destination_rt) et le
          trip_headsign publie dans le GTFS statique.

  PREREQUIS : wrk_passages, ref_feed_periode, stg_trips, stg_routes.
              Niveau de compatibilite >= 140 (STRING_AGG).

  IDEMPOTENT : DROP puis CREATE. Relancable autant de fois que necessaire,
               y compris apres un nouvel import de feed.

  ----------------------------------------------------------------------------
  POURQUOI CETTE TABLE EXISTE
  ----------------------------------------------------------------------------
  Le flux temps reel ne contient pas de trip_id. Le seul lien vers l'horaire
  theorique passe par le triplet (ligne, destination, arret). La destination
  est donc une CLE D'APPARIEMENT, pas un libelle decoratif : si elle ne se
  raccorde pas au GTFS, le passage reel n'a aucun theorique en face.

  ----------------------------------------------------------------------------
  LES SEPT CATEGORIES
  ----------------------------------------------------------------------------
    exact              egalite stricte avec un headsign DE LA MEME LIGNE
    devie              headsign GTFS de forme "ORIGINE -> DESTINATION" ;
                       l'API ne transmet que la partie droite
    abrege             variante typographique (7 regles manuelles)
    hors_service       RESERVE / PAS EN SERVICE : etat du vehicule, pas une
                       destination -> aucun theorique n'existe par definition
    inconnu            libelle 'INCONNU' emis par l'API
    ligne_incoherente  le libelle existe dans le GTFS mais sur une AUTRE
                       ligne -> attribution erronee du flux temps reel
    terminus_partiel   aucune correspondance nulle part

  ----------------------------------------------------------------------------
  LE PIEGE CORRIGE ICI  (a lire, il a deja coute)
  ----------------------------------------------------------------------------
  La premiere version du classement testait :

        WHERE EXISTS (SELECT 1 FROM stg_trips t
                      WHERE t.trip_headsign = p.destination)

  Cet EXISTS ne contraint PAS la ligne. Le couple (74, VAN HAELEN) a donc
  ete classe 'exact' parce que VAN HAELEN est un headsign... de la ligne 18.
  La ligne 74 n'annonce jamais ce headsign : elle publie
  "VICTOR ALLARD --> VAN HAELEN". 26 840 passages auraient echoue
  silencieusement a l'appariement.

  REGLE GENERALE : un EXISTS doit contraindre TOUTES les dimensions de
  l'appariement, pas seulement celle qui saute aux yeux. Meme piege que la
  jointure GTFS sans feed_version.

  Auteur : Omar
  Base   : TFE_STIB
  Mis en forme le 25/09/2026 : justification de la regle 82 remontee
  au-dessus de l'UPDATE qu'elle explique. Logique inchangee.
==============================================================================*/

USE TFE_STIB;
GO


/*==============================================================================
  SECTION 1 - STRUCTURE
  ----------------------------------------------------------------------------
  feed_version entre dans la cle primaire : un trip_headsign peut apparaitre
  ou disparaitre d'une publication a l'autre. Mesure : la regle
  "92 / SCHAERBEEK G." ne s'applique que dans UN seul des trois feeds.
  Sans feed_version, cette variation serait invisible.
==============================================================================*/

DROP TABLE IF EXISTS dbo.map_destination;

CREATE TABLE dbo.map_destination (
    feed_version   VARCHAR(50)  NOT NULL,
    line_id        VARCHAR(10)  NOT NULL,
    destination_rt VARCHAR(100) NOT NULL,
    trip_headsign  VARCHAR(255) NULL,      -- NULL = inappariable
    type_mapping   VARCHAR(20)  NOT NULL,
    commentaire    VARCHAR(255) NULL,
    CONSTRAINT pk_map_destination
        PRIMARY KEY (feed_version, line_id, destination_rt)
);
GO


/*==============================================================================
  SECTION 2 - CLASSEMENT
==============================================================================*/

WITH

/*--- 2a. Les couples reellement observes, rattaches a leur feed -------------
  On ne classe que ce qui existe dans les donnees. Le rattachement passe par
  la date de la derniere observation, resolue via ref_feed_periode.          */
observe AS (
    SELECT DISTINCT
           f.feed_version,
           p.line_id,
           p.destination AS destination_rt
    FROM dbo.wrk_passages p
    JOIN dbo.ref_feed_periode f
      ON CAST(p.derniere_obs AS DATE) BETWEEN f.date_debut AND f.date_fin
    WHERE p.destination IS NOT NULL
),

/*--- 2b. Les headsigns GTFS, par feed ET par ligne --------------------------
  La jointure passe par route_short_name : line_id du temps reel se joint
  sur route_short_name, JAMAIS sur route_id (88/88 contre 68/88).           */
hs AS (
    SELECT DISTINCT
           t.feed_version,
           r.route_short_name AS line_id,
           t.trip_headsign
    FROM dbo.stg_trips  t
    JOIN dbo.stg_routes r
      ON r.feed_version = t.feed_version
     AND r.route_id     = t.route_id
),

/*--- 2c. Les services devies ------------------------------------------------
  La STIB note ses deviations "ORIGINE -> DESTINATION" (parfois "-->").
  REVERSE + CHARINDEX localise la DERNIERE fleche : SQL Server n'a pas de
  fonction native pour chercher a partir de la fin. RIGHT recupere ce qui
  suit, LTRIM enleve l'espace. Le motif '%->%' attrape aussi '-->'.

  Six headsigns a fleche existent ; seuls DEUX seront retenus, ceux dont la
  partie droite est effectivement annoncee par l'API. Les quatre autres
  (dont "--> 75", qui designe un numero de ligne et non un arret) ne
  rencontrent aucun couple observe et disparaissent d'eux-memes.            */
hs_devie AS (
    SELECT feed_version,
           line_id,
           trip_headsign,
           LTRIM(RIGHT(trip_headsign,
                 CHARINDEX('>', REVERSE(trip_headsign)) - 1)) AS extrait
    FROM hs
    WHERE trip_headsign LIKE '%->%'
),

/*--- 2d. Les 7 regles typographiques manuelles ------------------------------
  Seule partie non reproductible du script : ce sont des jugements humains
  sur des variantes d'ecriture. Elles sont ecrites ici, en dur et commentees,
  precisement pour qu'elles soient visibles et discutables.
  Les cas devies (74, 82) NE SONT PAS ici : ils sont derives par la regle 2c. */
regle_abrege AS (
    SELECT * FROM (VALUES
        ('35' , 'SCHAERBEEK G.'   , 'SCHAERBEEK GARE'   , 'G. = GARE'),
        ('92' , 'SCHAERBEEK G.'   , 'SCHAERBEEK GARE'   , 'G. = GARE'),
        ('T92', 'SCHAERBEEK G.'   , 'SCHAERBEEK GARE'   , 'G. = GARE'),
        ('37' , 'GARE LINKEBEEK'  , 'GARE DE LINKEBEEK' , 'mot DE omis'),
        ('60' , 'PLACE SAINT-JOB' , 'PLACE ST-JOB'      , 'SAINT = ST'),
        ('63' , 'CIM.DE BRUXELLES', 'CIM. DE BRUXELLES' , 'espace apres le point'),
        ('95' , 'CIM. D''IXELLES' , 'CIM. IXELLES'      , 'apostrophe + D omis')
    ) v (line_id, destination_rt, trip_headsign, regle)
),

/*--- 2e. Recherche des candidats --------------------------------------------
  Un OUTER APPLY par piste. OUTER APPLY = LEFT JOIN capable d'utiliser les
  colonnes de la ligne courante ; il renvoie NULL si rien n'est trouve.
  Aucune piste n'exclut les autres a ce stade : on collecte, on tranchera
  ensuite dans le CASE.                                                      */
candidats AS (
    SELECT
        o.feed_version,
        o.line_id,
        o.destination_rt,
        c_exact.trip_headsign  AS hs_exact,
        c_devie.trip_headsign  AS hs_devie,
        c_abr.trip_headsign    AS hs_abrege,
        c_abr.regle            AS regle_abr,
        c_autre.lignes         AS lignes_du_libelle
    FROM observe o

    -- piste 1 : egalite stricte, MEME feed, MEME ligne
    OUTER APPLY (
        SELECT TOP 1 h.trip_headsign
        FROM hs h
        WHERE h.feed_version   = o.feed_version
          AND h.line_id        = o.line_id
          AND h.trip_headsign  = o.destination_rt
    ) c_exact

    -- piste 2 : partie droite d'un headsign a fleche
    OUTER APPLY (
        SELECT TOP 1 d.trip_headsign
        FROM hs_devie d
        WHERE d.feed_version = o.feed_version
          AND d.line_id      = o.line_id
          AND d.extrait      = o.destination_rt
    ) c_devie

    -- piste 3 : regle manuelle, VALIDEE contre le GTFS du feed courant
    --           (si le headsign cible n'existe pas dans ce feed, la regle
    --            ne s'applique pas : c'est le role de la jointure sur hs)
    OUTER APPLY (
        SELECT TOP 1 ra.trip_headsign, ra.regle
        FROM regle_abrege ra
        JOIN hs h
          ON h.feed_version  = o.feed_version
         AND h.line_id       = o.line_id
         AND h.trip_headsign = ra.trip_headsign
        WHERE ra.line_id        = o.line_id
          AND ra.destination_rt = o.destination_rt
    ) c_abr

    -- piste 4 : le libelle existe-t-il sur une AUTRE ligne ?
    --           On agrege TOUTES les lignes concernees. Un "TOP 1" sans
    --           ORDER BY renverrait une ligne arbitraire et surtout NON
    --           DETERMINISTE : deux executions pourraient donner deux
    --           resultats differents. Piege classique.
    OUTER APPLY (
        SELECT STRING_AGG(x.line_id, ', ')
                 WITHIN GROUP (ORDER BY x.line_id) AS lignes
        FROM (
            SELECT DISTINCT h.line_id
            FROM hs h
            WHERE h.feed_version  = o.feed_version
              AND h.trip_headsign = o.destination_rt
              AND h.line_id      <> o.line_id
        ) x
    ) c_autre
)

INSERT INTO dbo.map_destination
       (feed_version, line_id, destination_rt, trip_headsign, type_mapping, commentaire)
SELECT
    feed_version,
    line_id,
    destination_rt,

    /* Le headsign retenu : celui de la piste qui a gagne. COALESCE prend la
       premiere valeur non NULL, dans l'ordre de priorite du CASE ci-dessous. */
    CASE WHEN destination_rt IN ('INCONNU', 'RESERVE', 'PAS EN SERVICE')
         THEN NULL
         ELSE COALESCE(hs_exact, hs_devie, hs_abrege)
    END,

    /* Les libelles non commerciaux sont traites EN PREMIER : sans cela,
       'RESERVE' existe comme headsign GTFS et serait classe 'exact', alors
       qu'aucune course commerciale ne lui correspond.                       */
    CASE
        WHEN destination_rt = 'INCONNU'                       THEN 'inconnu'
        WHEN destination_rt IN ('RESERVE', 'PAS EN SERVICE')  THEN 'hors_service'
        WHEN hs_exact           IS NOT NULL                   THEN 'exact'
        WHEN hs_devie           IS NOT NULL                   THEN 'devie'
        WHEN hs_abrege          IS NOT NULL                   THEN 'abrege'
        WHEN lignes_du_libelle  IS NOT NULL                   THEN 'ligne_incoherente'
        ELSE                                                       'terminus_partiel'
    END,

    CASE
        WHEN destination_rt = 'INCONNU'
             THEN 'libelle emis par l''API quand la destination est indisponible'
        WHEN destination_rt IN ('RESERVE', 'PAS EN SERVICE')
             THEN 'etat du vehicule, pas une destination - a exclure de fact_ecart'
        WHEN hs_exact  IS NOT NULL THEN NULL
        WHEN hs_devie  IS NOT NULL THEN 'service devie - partie droite du headsign GTFS'
        WHEN hs_abrege IS NOT NULL THEN 'regle typographique : ' + regle_abr
        WHEN lignes_du_libelle IS NOT NULL
             THEN LEFT('libelle appartenant aux lignes ' + lignes_du_libelle
                       + ' - attribution erronee du flux temps reel', 255)
        ELSE 'aucune correspondance GTFS - service partiel exceptionnel presume'
    END
FROM candidats;
GO

/*-----------------------------------------------------------------------------
  Règle manuelle : 82 / DROGENBOS/DIEWEG  (785 passages, feed 2_18 uniquement)

  L'extraction par la flèche sur 'CARR. STALLE -> DIEWEG' produit 'DIEWEG',
  jamais 'DROGENBOS/DIEWEG'. Aucune règle générale ne peut rattacher ce
  libellé : il échappe par construction et doit être traité explicitement.

  Justification externe : depuis le 06/06 et jusqu'en 2028, le 82 remplace
  le 97 entre Carr. Stalle et Dieweg ; Drogenbos n'est plus desservi
  (correspondance par le 74 à Carr. Stalle). 'DROGENBOS/DIEWEG' est donc un
  affichage informatif de l'API, pas une destination distincte.
-----------------------------------------------------------------------------*/

UPDATE dbo.map_destination
SET    trip_headsign = 'CARR. STALLE -> DIEWEG',
       type_mapping  = 'devie',
       commentaire   = 'regle manuelle : affichage informatif, terminus reel = DIEWEG'
WHERE  line_id        = '82'
  AND  destination_rt = 'DROGENBOS/DIEWEG'
  AND  EXISTS (SELECT 1 FROM dbo.stg_trips t
               JOIN dbo.stg_routes r ON r.feed_version = t.feed_version
                                    AND r.route_id     = t.route_id
               WHERE t.feed_version   = map_destination.feed_version
                 AND r.route_short_name = '82'
                 AND t.trip_headsign  = 'CARR. STALLE -> DIEWEG');
GO


/*==============================================================================
  SECTION 3 - CONTROLES
  ----------------------------------------------------------------------------
  Un script de transformation sans controle n'est pas termine. Ces requetes
  produisent les chiffres a reprendre dans le rapport.
==============================================================================*/

PRINT '=== 3.1 - Repartition EN VOLUME DE PASSAGES ===';
-- C'est le volume qui decide, jamais le nombre de couples : 136 couples a
-- 0,10 % du trafic ne sont pas un probleme, 1 couple a 1,4 % en est un.
-- Attendu : exact ~95,3 / devie ~2,2 / abrege ~1,7 / inconnu ~0,5 /
--           ligne_incoherente ~0,13 / terminus_partiel ~0,10 /
--           hors_service ~0,07
WITH vol AS (
    SELECT f.feed_version, p.line_id, p.destination, COUNT(*) AS nb_passages
    FROM dbo.wrk_passages p
    JOIN dbo.ref_feed_periode f
      ON CAST(p.derniere_obs AS DATE) BETWEEN f.date_debut AND f.date_fin
    GROUP BY f.feed_version, p.line_id, p.destination
)
SELECT
    m.type_mapping,
    COUNT(*)                              AS nb_couples,
    SUM(ISNULL(v.nb_passages, 0))         AS nb_passages,
    CAST(100.0 * SUM(ISNULL(v.nb_passages, 0))
         / SUM(SUM(ISNULL(v.nb_passages, 0))) OVER ()
         AS DECIMAL(5,2))                 AS pct_trafic
FROM dbo.map_destination m
LEFT JOIN vol v
       ON v.feed_version = m.feed_version
      AND v.line_id      = m.line_id
      AND v.destination  = m.destination_rt
GROUP BY m.type_mapping
ORDER BY nb_passages DESC;


PRINT '=== 3.2 - Couverture : tout passage doit trouver son classement ===';
-- La ligne '### NON CLASSE ###' ne doit PAS apparaitre, et le total doit
-- valoir exactement COUNT(*) de wrk_passages (3 312 727).
SELECT
    ISNULL(m.type_mapping, '### NON CLASSE ###') AS type_mapping,
    COUNT(*) AS nb_passages
FROM dbo.wrk_passages p
LEFT JOIN dbo.ref_feed_periode f
       ON CAST(p.derniere_obs AS DATE) BETWEEN f.date_debut AND f.date_fin
LEFT JOIN dbo.map_destination m
       ON m.feed_version   = f.feed_version
      AND m.line_id        = p.line_id
      AND m.destination_rt = p.destination
GROUP BY ISNULL(m.type_mapping, '### NON CLASSE ###')
ORDER BY nb_passages DESC;


PRINT '=== 3.3 - Controle de non-regression sur les cas devies ===';
-- Doit renvoyer 6 lignes, toutes en type_mapping = 'devie'.
-- Si 'exact' reapparait sur la ligne 74, l'EXISTS non contraint est revenu.
SELECT feed_version, line_id, destination_rt, trip_headsign, type_mapping
FROM dbo.map_destination
WHERE (line_id = '74' AND destination_rt = 'VAN HAELEN')
   OR (line_id = '82' AND destination_rt IN ('DIEWEG', 'DROGENBOS/DIEWEG'))
ORDER BY line_id, feed_version;


PRINT '=== 3.4 - Les 7 regles manuelles se sont-elles toutes appliquees ? ===';
-- Une regle qui ne s'applique dans AUCUN feed est une regle morte :
-- soit le libelle a change, soit elle etait fausse. A verifier, pas a ignorer.
-- Mesure connue : "92 / SCHAERBEEK G." ne vaut que pour UN feed, la branche
-- nord etant assuree par T92 dans les deux autres.
SELECT line_id, destination_rt, COUNT(*) AS nb_feeds_concernes
FROM dbo.map_destination
WHERE type_mapping = 'abrege'
GROUP BY line_id, destination_rt
ORDER BY line_id;


PRINT '=== 3.5 - Detail des attributions incoherentes du flux temps reel ===';
-- Mesure de la qualite de la source, a chiffrer dans le rapport (~0,13 %).
-- Trois motifs attendus : paires de metro partageant un tronc (1/5),
-- grands poles multi-lignes (GARE CENTRALE, LUXEMBOURG), et bruit residuel.
WITH vol AS (
    SELECT f.feed_version, p.line_id, p.destination, COUNT(*) AS nb_passages
    FROM dbo.wrk_passages p
    JOIN dbo.ref_feed_periode f
      ON CAST(p.derniere_obs AS DATE) BETWEEN f.date_debut AND f.date_fin
    GROUP BY f.feed_version, p.line_id, p.destination
)
SELECT TOP 30
    m.line_id, m.destination_rt, m.commentaire,
    SUM(ISNULL(v.nb_passages, 0)) AS nb_passages
FROM dbo.map_destination m
LEFT JOIN vol v
       ON v.feed_version = m.feed_version
      AND v.line_id      = m.line_id
      AND v.destination  = m.destination_rt
WHERE m.type_mapping = 'ligne_incoherente'
GROUP BY m.line_id, m.destination_rt, m.commentaire
ORDER BY nb_passages DESC;
GO


/*==============================================================================
  NOTE POUR LE RAPPORT
  ----------------------------------------------------------------------------
  Taux d'appariabilite : 99,19 % du trafic (exact + devie + abrege).
  Les 0,81 % restants sont tous categorises avec une cause nommee et mesuree.

  Six des sept categories sont produites par regle et donc entierement
  reproductibles. Une seule repose sur des decisions humaines : les sept
  variantes typographiques de la section 2d, ecrites en dur et commentees
  une par une.

  La categorie 'devie' merite d'etre expliquee a l'oral : elle a ete obtenue
  en GENERANT des candidats par transformation (partie droite de la fleche),
  puis en ne RETENANT que ceux confirmes par les libelles reellement observes
  dans le flux temps reel. Sur six candidats generes, deux seulement ont ete
  valides. Les quatre autres (dont "--> 75", qui designe un numero de ligne
  et non un arret) ont ete ecartes par la confrontation aux donnees.

  Une regle de nettoyage se verifie sur les donnees ; elle ne s'applique
  jamais a l'aveugle parce que le motif semblait evident.
==============================================================================*/
