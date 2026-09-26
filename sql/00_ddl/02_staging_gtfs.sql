/*=============================================================================
  TFE STIB - 00_ddl/02_staging_gtfs.sql
  ----------------------------------------------------------------------------
  OBJET : creer les six tables de l'horaire theorique GTFS, avec leurs cles
          et les index de travail. Alimentees par python/import_gtfs.ipynb
          (trois feeds : 2_15, 2_16, 2_18).

  POURQUOI feed_version DANS TOUTES LES CLES
  ----------------------------------------------------------------------------
  Les trois feeds sont charges dans les memes tables. Un trip_id ou un
  service_id n'est unique qu'A L'INTERIEUR d'un feed : sans feed_version
  dans la cle, deux publications entreraient en collision, et une jointure
  GTFS sans feed_version dupliquerait les lignes sans aucune erreur.

  POURQUOI DES VARCHAR PARTOUT
  ----------------------------------------------------------------------------
  Les identifiants restent en texte : 0089, 0470F, T92 ou M1 ne sont pas
  des nombres, et un zero initial perdu casserait les jointures. Les
  heures GTFS peuvent depasser 24:00:00 (course apres minuit) : elles ne
  se convertissent pas en TIME, d'ou arrivee_sec ci-dessous.
  Seule exception : stop_sequence en INT, parce qu'il sert a ORDONNER.

  arrivee_sec : l'heure theorique en secondes depuis minuit, colonne
  calculee et persistee. '25:30:00' donne 91 800, la ou un CAST en TIME
  echouerait.
  stop_id_racine et son index ix_sst_racine NE sont PAS ici : ils sont
  poses par 04_stop_id_racine.sql, qui en est le seul proprietaire.

  ORDRE DE CHARGEMENT impose par les cles etrangeres :
      stg_calendar, stg_routes, stg_stops
   -> stg_trips, stg_calendar_dates
   -> stg_stop_times

  CREATION SEULEMENT SI ABSENTE : relancer le script sur une base chargee
  ne detruit rien. Pour repartir de zero, supprimer les tables a la main,
  dans l'ordre inverse du chargement.

  ORIGINE : structure extraite de la base le 25/09/2026 (SSMS, Generer des
            scripts). Remplace les CREATE TABLE d'aout, faits a la main.
=============================================================================*/

USE TFE_STIB;
GO

IF OBJECT_ID('dbo.stg_calendar') IS NULL
    CREATE TABLE dbo.stg_calendar (
        feed_version VARCHAR(50) NOT NULL,
        service_id   VARCHAR(50) NOT NULL,
        monday       VARCHAR(5)  NULL,
        tuesday      VARCHAR(5)  NULL,
        wednesday    VARCHAR(5)  NULL,
        thursday     VARCHAR(5)  NULL,
        friday       VARCHAR(5)  NULL,
        saturday     VARCHAR(5)  NULL,
        sunday       VARCHAR(5)  NULL,
        start_date   VARCHAR(20) NULL,
        end_date     VARCHAR(20) NULL,
        CONSTRAINT PK_stg_calendar PRIMARY KEY (feed_version, service_id)
    );
GO

IF OBJECT_ID('dbo.stg_routes') IS NULL
    CREATE TABLE dbo.stg_routes (
        feed_version     VARCHAR(50)  NOT NULL,
        route_id         VARCHAR(50)  NOT NULL,
        agency_id        VARCHAR(50)  NULL,
        route_short_name VARCHAR(50)  NULL,   -- = line_id du temps reel
        route_long_name  VARCHAR(255) NULL,
        route_desc       VARCHAR(255) NULL,
        route_type       VARCHAR(50)  NULL,
        route_url        VARCHAR(255) NULL,
        route_color      VARCHAR(50)  NULL,
        route_text_color VARCHAR(50)  NULL,
        CONSTRAINT PK_stg_routes PRIMARY KEY (feed_version, route_id)
    );
GO

IF OBJECT_ID('dbo.stg_stops') IS NULL
    CREATE TABLE dbo.stg_stops (
        feed_version   VARCHAR(50)  NOT NULL,
        stop_id        VARCHAR(50)  NOT NULL,
        stop_code      VARCHAR(50)  NULL,
        stop_name      VARCHAR(255) NULL,
        stop_desc      VARCHAR(255) NULL,
        stop_lat       VARCHAR(50)  NULL,
        stop_lon       VARCHAR(50)  NULL,
        zone_id        VARCHAR(50)  NULL,
        stop_url       VARCHAR(255) NULL,
        location_type  VARCHAR(50)  NULL,
        parent_station VARCHAR(50)  NULL,
        CONSTRAINT PK_stg_stops PRIMARY KEY (feed_version, stop_id),
        CONSTRAINT FK_stg_stops_parent FOREIGN KEY (feed_version, parent_station)
            REFERENCES dbo.stg_stops (feed_version, stop_id)
    );
GO

IF OBJECT_ID('dbo.stg_trips') IS NULL
    CREATE TABLE dbo.stg_trips (
        feed_version  VARCHAR(50)  NOT NULL,
        route_id      VARCHAR(50)  NOT NULL,
        service_id    VARCHAR(50)  NOT NULL,
        trip_id       VARCHAR(50)  NOT NULL,
        trip_headsign VARCHAR(255) NULL,
        direction_id  VARCHAR(50)  NULL,
        block_id      VARCHAR(50)  NULL,
        shape_id      VARCHAR(50)  NULL,
        CONSTRAINT PK_stg_trips PRIMARY KEY (feed_version, trip_id),
        CONSTRAINT FK_stg_trips_routes FOREIGN KEY (feed_version, route_id)
            REFERENCES dbo.stg_routes (feed_version, route_id),
        CONSTRAINT FK_stg_trips_calendar FOREIGN KEY (feed_version, service_id)
            REFERENCES dbo.stg_calendar (feed_version, service_id)
    );
GO

IF OBJECT_ID('dbo.stg_calendar_dates') IS NULL
    CREATE TABLE dbo.stg_calendar_dates (
        feed_version   VARCHAR(50) NOT NULL,
        service_id     VARCHAR(50) NOT NULL,
        date           VARCHAR(8)  NOT NULL,   -- AAAAMMJJ
        exception_type VARCHAR(50) NULL,       -- 1 = ajout, 2 = suppression
        CONSTRAINT PK_stg_calendar_dates PRIMARY KEY (feed_version, service_id, date),
        CONSTRAINT FK_stg_calendar_dates_calendar FOREIGN KEY (feed_version, service_id)
            REFERENCES dbo.stg_calendar (feed_version, service_id)
    );
GO

IF OBJECT_ID('dbo.stg_stop_times') IS NULL
    CREATE TABLE dbo.stg_stop_times (
        feed_version        VARCHAR(50)  NOT NULL,
        trip_id             VARCHAR(50)  NOT NULL,
        arrival_time        VARCHAR(50)  NULL,
        departure_time      VARCHAR(50)  NULL,
        stop_id             VARCHAR(50)  NOT NULL,
        stop_sequence       INT          NOT NULL,
        stop_headsign       VARCHAR(255) NULL,
        pickup_type         VARCHAR(50)  NULL,
        drop_off_type       VARCHAR(50)  NULL,
        shape_dist_traveled VARCHAR(50)  NULL,
        arrivee_sec AS (
              TRY_CAST(LEFT(arrival_time, 2)         AS INT) * 3600
            + TRY_CAST(SUBSTRING(arrival_time, 4, 2) AS INT) * 60
            + TRY_CAST(RIGHT(arrival_time, 2)        AS INT)
        ) PERSISTED,
        CONSTRAINT PK_stg_stop_times PRIMARY KEY (feed_version, trip_id, stop_sequence),
        CONSTRAINT FK_stg_stop_times_trips FOREIGN KEY (feed_version, trip_id)
            REFERENCES dbo.stg_trips (feed_version, trip_id),
        CONSTRAINT FK_stg_stop_times_stops FOREIGN KEY (feed_version, stop_id)
            REFERENCES dbo.stg_stops (feed_version, stop_id)
    );
GO


/*=============================================================================
  INDEX DE TRAVAIL
  ----------------------------------------------------------------------------
  stg_stop_times compte ~5,7 M de lignes. Sans ces index, l'explosion de
  l'horaire (40_int_passage_theorique) prend plusieurs minutes.
  Crees seulement s'ils n'existent pas.
=============================================================================*/

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_stop_times_trip'
               AND object_id = OBJECT_ID('dbo.stg_stop_times'))
    CREATE INDEX ix_stop_times_trip ON dbo.stg_stop_times (feed_version, trip_id)
        INCLUDE (stop_id, stop_sequence, arrivee_sec);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_stg_stop_times_stop'
               AND object_id = OBJECT_ID('dbo.stg_stop_times'))
    CREATE INDEX IX_stg_stop_times_stop ON dbo.stg_stop_times (feed_version, stop_id);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_trips_service'
               AND object_id = OBJECT_ID('dbo.stg_trips'))
    CREATE INDEX ix_trips_service ON dbo.stg_trips (feed_version, service_id)
        INCLUDE (trip_id, route_id, trip_headsign, direction_id);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_stg_trips_route'
               AND object_id = OBJECT_ID('dbo.stg_trips'))
    CREATE INDEX IX_stg_trips_route ON dbo.stg_trips (feed_version, route_id);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_calendar_dates_lookup'
               AND object_id = OBJECT_ID('dbo.stg_calendar_dates'))
    CREATE INDEX ix_calendar_dates_lookup ON dbo.stg_calendar_dates (feed_version, service_id, date);
GO
