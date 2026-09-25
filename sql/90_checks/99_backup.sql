/*=============================================================================
  TFE STIB - 99_backup.sql  (V2)
  ----------------------------------------------------------------------------
  OBJET : sauvegarder TFE_STIB et sortir les fichiers de la machine.

  V2 - 19/09/2026 : adapte au PC personnel.
    - Dossier de destination parametre en UN seul endroit (@dossier).
    - Date des noms de fichiers calculee automatiquement (GETDATE) :
      avec FORMAT, reutiliser par erreur les noms d'un ancien jeu
      l'ECRASERAIT sans avertissement. Des noms dates du jour rendent
      cette erreur impossible (seule une 2e execution le meme jour
      remplace le jeu du jour, ce qui est voulu).
    - Sauvegarde et verification dans le MEME lot : les variables
      ne survivent pas a un GO.

  POURQUOI, ET LE VRAI MOTIF
  ----------------------------------------------------------------------------
  La couche derivee (wrk_*, int_*, dim_*, fact_ecart) se reconstruit en
  relancant les scripts numerotes : le rejeu complet du 19/09 l'a prouve
  une seconde fois, sur une autre machine et a 52 jours.

  Le motif est staging_waiting_times : 33 480 270 lignes, dont ~3,2 M
  collectees entre le 19 et le 26 aout. L'API WaitingTimes ne publie
  que l'instant present : cette donnee ne se recollecte pas.
  La meteo (Open-Meteo ERA5), elle, se retelecharge.

  ⚠️ LES FICHIERS .bak SONT INDISSOCIABLES. Un seul ne sert a rien.
  ⚠️ Un .bak ne se restaure JAMAIS vers une version anterieure de
     SQL Server.
  ⚠️ Prevoir ~9 Go libres a la restauration.
  ⚠️ Le compte de service SQL Server (NT Service\MSSQLSERVER) doit avoir
     le droit d'ECRITURE sur @dossier. Sinon : Operating system error 5.
  ⚠️ Ne JAMAIS supprimer le jeu du 03/09 : c'est la seule copie des
     donnees brutes dans leur etat d'origine.
=============================================================================*/

USE master;
GO

/*----------------------------------------------------------------------------
  0. Etat avant sauvegarde
----------------------------------------------------------------------------*/
SELECT  name, recovery_model_desc, log_reuse_wait_desc
FROM    sys.databases
WHERE   name = 'TFE_STIB';

SELECT  fichier = name, type_desc,
        taille_mb = CAST(size * 8.0 / 1024 AS DECIMAL(10,1))
FROM    sys.master_files
WHERE   database_id = DB_ID('TFE_STIB');
GO


/*----------------------------------------------------------------------------
  1. Reduire le journal AVANT de sauvegarder
  ----------------------------------------------------------------------------
  Si log_reuse_wait_desc renvoie ACTIVE_TRANSACTION, un BEGIN TRAN
  traine dans un onglet SSMS : le journal ne se tronquera pas. Fermer
  l'onglet fautif d'abord (piege n°19).
----------------------------------------------------------------------------*/
USE TFE_STIB;
GO

ALTER DATABASE TFE_STIB SET RECOVERY SIMPLE;
GO

DBCC SHRINKFILE (TFE_STIB_log, 512);
GO


/*----------------------------------------------------------------------------
  2. Sauvegarde sur 4 fichiers + 3. verification
  ----------------------------------------------------------------------------
  COPY_ONLY   : ne perturbe aucune chaine de sauvegarde existante.
  COMPRESSION : ratio ~4,5 mesure le 21/08 et le 03/09.
  CHECKSUM    : detecte une corruption a l'ecriture.
  FORMAT      : ecrase les fichiers de MEME NOM (d'ou les noms dates).

  Une sauvegarde non verifiee n'est pas une sauvegarde : RESTORE
  VERIFYONLY relit les 4 fichiers sans rien restaurer.
----------------------------------------------------------------------------*/
USE master;
GO

DECLARE @dossier NVARCHAR(260) = N'C:\Users\omar\Desktop\backup\';   -- <- SEUL PARAMETRE
DECLARE @jour    CHAR(8)       = CONVERT(CHAR(8), GETDATE(), 112);   -- AAAAMMJJ

DECLARE @f1  NVARCHAR(300) = @dossier + N'TFE_STIB_' + @jour + N'_01.bak';
DECLARE @f2  NVARCHAR(300) = @dossier + N'TFE_STIB_' + @jour + N'_02.bak';
DECLARE @f3  NVARCHAR(300) = @dossier + N'TFE_STIB_' + @jour + N'_03.bak';
DECLARE @f4  NVARCHAR(300) = @dossier + N'TFE_STIB_' + @jour + N'_04.bak';
DECLARE @nom NVARCHAR(128) = N'TFE_STIB - snapshot ' + CONVERT(CHAR(10), GETDATE(), 23)
                           + N' - 52 jours, rejeu complet';

PRINT 'Destination : ' + @f1 + ' (+ _02, _03, _04)';

BACKUP DATABASE TFE_STIB
TO  DISK = @f1, DISK = @f2, DISK = @f3, DISK = @f4
WITH    COPY_ONLY,
        COMPRESSION,
        CHECKSUM,
        FORMAT,
        STATS = 5,
        NAME = @nom;

RESTORE VERIFYONLY
FROM DISK = @f1, DISK = @f2, DISK = @f3, DISK = @f4
WITH CHECKSUM;
GO


/*----------------------------------------------------------------------------
  4. Bilan chiffre - a noter dans etat-du-projet.md
----------------------------------------------------------------------------*/
SELECT TOP 1
        name,
        backup_finish_date,
        taille_donnees_mb = CAST(backup_size / 1024.0 / 1024 AS DECIMAL(10,1)),
        taille_fichier_mb = CAST(compressed_backup_size / 1024.0 / 1024 AS DECIMAL(10,1)),
        ratio             = CAST(backup_size * 1.0 / compressed_backup_size AS DECIMAL(5,2))
FROM    msdb.dbo.backupset
WHERE   database_name = 'TFE_STIB'
ORDER BY backup_finish_date DESC;
GO

/*=============================================================================
  5. APRES L'EXECUTION - LA PARTIE QUI COMPTE VRAIMENT

  Copier les 4 fichiers HORS DE LA MACHINE (Drive, disque externe).
  Un backup qui reste sur la machine qu'il protege ne protege rien.

  Emporter aussi, dans le meme dossier :
    - les 3 ZIP GTFS (2_15, 2_16, 2_18)
    - le dossier complet des scripts numerotes
=============================================================================*/
