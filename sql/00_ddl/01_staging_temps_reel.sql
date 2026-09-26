/*=============================================================================
  TFE STIB - 00_ddl/01_staging_temps_reel.sql
  ----------------------------------------------------------------------------
  OBJET : creer les tables qui recoivent le flux temps reel de l'API STIB.
          Alimentees par python/collecte.py (toutes les 3 minutes,
          09:00 -> 14:00, du 01/07 au 26/08/2026).

  /!\ CE SCRIPT NE SUPPRIME JAMAIS RIEN
  ----------------------------------------------------------------------------
  Contrairement aux autres scripts de la chaine, il n'est PAS construit en
  "DROP puis CREATE". staging_waiting_times (~33,5 M de lignes) est
  IRREPRODUCTIBLE : l'API ne publie que l'instant present. Un DROP la
  detruirait definitivement. Chaque table n'est donc creee QUE si elle
  n'existe pas encore : relancer le script sur la base existante ne fait rien.

  TYPAGE
  ----------------------------------------------------------------------------
  expected_arrival est stocke en texte, tel que l'API le publie (ISO 8601
  avec fuseau). Le typage est fait en aval (20_wrk_observations.sql), pas
  au chargement : une valeur mal formee ne doit pas faire echouer la
  collecte, dont chaque cycle perdu est perdu pour toujours.

  ORIGINE : structure extraite de la base le 25/09/2026 (SSMS, Generer des
            scripts), identique aux tables creees en juillet 2026.
=============================================================================*/

USE TFE_STIB;
GO

/*--- Temps d'attente annonces : LA source du reel -------------------------
  Grain : 1 ligne = 1 prediction (arret x ligne x destination x cycle).
  Un cycle publie en general les deux prochains vehicules.               */
IF OBJECT_ID('dbo.staging_waiting_times') IS NULL
    CREATE TABLE dbo.staging_waiting_times (
        id               INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        collected_at     DATETIME     NULL,
        point_id         VARCHAR(10)  NULL,
        line_id          VARCHAR(5)   NULL,
        destination      VARCHAR(100) NULL,
        expected_arrival VARCHAR(50)  NULL,
        wait_minutes     FLOAT        NULL
    );
GO

/*--- Positions des vehicules : collectees, non utilisees ------------------
  Conservees en reserve. Aucun script de la chaine ne les lit.           */
IF OBJECT_ID('dbo.staging_vehicle_positions') IS NULL
    CREATE TABLE dbo.staging_vehicle_positions (
        id                  INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        collected_at        DATETIME    NULL,
        line_id             VARCHAR(5)  NULL,
        direction_id        VARCHAR(10) NULL,
        point_id            VARCHAR(10) NULL,
        distance_from_point INT         NULL
    );
GO

/*--- Referentiel des arrets temps reel : charge une seule fois ------------*/
IF OBJECT_ID('dbo.staging_stop_details') IS NULL
    CREATE TABLE dbo.staging_stop_details (
        id        INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        point_id  VARCHAR(10)  NULL,
        nom_fr    VARCHAR(100) NULL,
        nom_nl    VARCHAR(100) NULL,
        latitude  FLOAT        NULL,
        longitude FLOAT        NULL
    );
GO
