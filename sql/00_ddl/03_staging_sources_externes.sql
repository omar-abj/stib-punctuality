/*=============================================================================
  TFE STIB - 00_ddl/03_staging_sources_externes.sql
  ----------------------------------------------------------------------------
  OBJET : creer les tables des sources hors STIB temps reel.

    staging_meteo              Open-Meteo (ERA5), 1 ligne = 1 heure,
                               heure locale de Bruxelles
                               -> python/import_meteo.ipynb
    staging_line_exploitation  type d'exploitation par ligne
                               -> python/import_exploitation.ipynb
    staging_secteur_stat       Statbel : population et superficie par
                               secteur statistique
    staging_revenu_commune     Statbel : revenu median par commune
                               -> python/import_statbel.ipynb

  Tout est en texte, comme recu. Le typage est fait par les dimensions
  (TRY_CAST dans 56_dim_meteo.sql par exemple), pas au chargement.

  Les deux tables Statbel n'ont pas de cle primaire : elles sont chargees
  pour une analyse d'equite territoriale qui n'est pas encore dans la
  chaine. Les notebooks les vident avant chaque chargement.

  CREATION SEULEMENT SI ABSENTE, comme 01 et 02.

  ORIGINE : structure extraite de la base le 25/09/2026 (SSMS, Generer des
            scripts).
=============================================================================*/

USE TFE_STIB;
GO

IF OBJECT_ID('dbo.staging_meteo') IS NULL
    CREATE TABLE dbo.staging_meteo (
        date_heure_local VARCHAR(50) NOT NULL PRIMARY KEY,
        date_locale      VARCHAR(50) NULL,
        heure_locale     VARCHAR(50) NULL,
        temperature_2m   VARCHAR(50) NULL,
        apparent_temp    VARCHAR(50) NULL,
        humidite_rel     VARCHAR(50) NULL,
        precipitation_mm VARCHAR(50) NULL,
        pluie_mm         VARCHAR(50) NULL,
        neige_cm         VARCHAR(50) NULL,
        code_meteo       VARCHAR(50) NULL,
        vent_kmh         VARCHAR(50) NULL,
        rafales_kmh      VARCHAR(50) NULL,
        couverture_nuage VARCHAR(50) NULL
    );
GO

IF OBJECT_ID('dbo.staging_line_exploitation') IS NULL
    CREATE TABLE dbo.staging_line_exploitation (
        line_id           VARCHAR(10)  NOT NULL PRIMARY KEY,
        type_exploitation NVARCHAR(30) NOT NULL
    );
GO

IF OBJECT_ID('dbo.staging_secteur_stat') IS NULL
    CREATE TABLE dbo.staging_secteur_stat (
        cd_refnis      VARCHAR(50)  NULL,
        cd_sector      VARCHAR(50)  NULL,
        population     VARCHAR(50)  NULL,
        superficie_hm2 VARCHAR(50)  NULL,
        nom_secteur_fr VARCHAR(100) NULL,
        nom_commune_fr VARCHAR(100) NULL
    );
GO

IF OBJECT_ID('dbo.staging_revenu_commune') IS NULL
    CREATE TABLE dbo.staging_revenu_commune (
        cd_refnis     VARCHAR(50)  NULL,
        nom_commune   VARCHAR(100) NULL,
        annee         VARCHAR(50)  NULL,
        revenu_median VARCHAR(50)  NULL
    );
GO
