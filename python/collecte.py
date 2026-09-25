"""
Collecte du flux temps reel STIB -> SQL Server (staging).

Lance toutes les 3 minutes par le Planificateur de taches Windows,
de 09:00 a 14:00, du 01/07 au 26/08/2026 (100 appels par jour, la limite
de l'API).

Configuration par variables d'environnement, jamais dans le code :
    STIB_API_KEY     cle d'abonnement du portail opendata.stib-mivb.be
    STIB_SQL_SERVER  serveur SQL Server (defaut : localhost)
    STIB_SQL_DB      base de donnees     (defaut : TFE_STIB)

Tables cibles : sql/00_ddl/01_staging_temps_reel.sql
"""

import json
import os
import sys
from datetime import datetime

import pyodbc
import requests

API_KEY = os.environ.get("STIB_API_KEY")
if not API_KEY:
    sys.exit("Variable d'environnement STIB_API_KEY absente : collecte annulee.")

BASE_URL = "https://api-management-opendata-production.azure-api.net/api/datasets/stibmivb"

CONNECTION = (
    "DRIVER={SQL Server};"
    f"SERVER={os.environ.get('STIB_SQL_SERVER', 'localhost')};"
    f"DATABASE={os.environ.get('STIB_SQL_DB', 'TFE_STIB')};"
    "Trusted_Connection=yes"
)


# ─────────────────────────────────────────
# 1. WAITING TIMES
# ─────────────────────────────────────────
def collecter_waiting_times(cursor, collected_at):
    rows   = []
    offset = 0
    limit  = 1000

    while True:
        response = requests.get(
            f"{BASE_URL}/rt/WaitingTimes",
            headers={"bmc-partner-key": API_KEY},
            params={"limit": limit, "offset": offset}
        )
        data    = response.json()
        results = data.get("results", [])

        if not results:
            break

        for record in results:
            point_id          = record.get("pointid")
            line_id           = record.get("lineid")
            passing_times_raw = record.get("passingtimes")

            if not passing_times_raw:
                continue

            for passage in json.loads(passing_times_raw):
                arrival_str     = passage.get("expectedArrivalTime")
                destination_raw = passage.get("destination", {})
                destination_fr  = destination_raw.get("fr", "INCONNU")

                if not arrival_str:
                    continue

                arrival_naive = datetime.fromisoformat(arrival_str).replace(tzinfo=None)
                wait_minutes  = round((arrival_naive - collected_at).total_seconds() / 60, 2)

                rows.append((collected_at, point_id, line_id, destination_fr, arrival_str, wait_minutes))

        offset += limit

        if len(results) < limit:
            break

    cursor.executemany("""
        INSERT INTO staging_waiting_times
        (collected_at, point_id, line_id, destination, expected_arrival, wait_minutes)
        VALUES (?, ?, ?, ?, ?, ?)
    """, rows)

    print(f"  ✔ WaitingTimes     → {len(rows)} lignes insérées")


# ─────────────────────────────────────────
# 2. VEHICLE POSITIONS
# ─────────────────────────────────────────
def collecter_vehicle_positions(cursor, collected_at):
    response = requests.get(
        f"{BASE_URL}/rt/VehiclePositions",
        headers={"bmc-partner-key": API_KEY},
        params={"limit": 1000}
    )
    data = response.json()
    rows = []

    for record in data["results"]:
        line_id       = record.get("lineid")
        positions_raw = record.get("vehiclepositions")

        if not positions_raw:
            continue

        for pos in json.loads(positions_raw):
            direction_id        = pos.get("directionId")
            point_id            = pos.get("pointId")
            distance_from_point = pos.get("distanceFromPoint")

            rows.append((collected_at, line_id, direction_id, point_id, distance_from_point))

    cursor.executemany("""
        INSERT INTO staging_vehicle_positions
        (collected_at, line_id, direction_id, point_id, distance_from_point)
        VALUES (?, ?, ?, ?, ?)
    """, rows)

    print(f"  ✔ VehiclePositions → {len(rows)} lignes insérées")


# ─────────────────────────────────────────
# 3. STOP DETAILS (une seule fois, hors cycle automatique)
# ─────────────────────────────────────────
def collecter_stop_details(cursor):
    rows   = []
    offset = 0
    limit  = 1000

    while True:
        response = requests.get(
            f"{BASE_URL}/static/StopDetails",
            headers={"bmc-partner-key": API_KEY},
            params={"limit": limit, "offset": offset}
        )
        data    = response.json()
        results = data.get("results", [])

        if not results:
            break

        for record in results:
            point_id = record.get("id")

            name_raw = record.get("name", "{}")
            name     = json.loads(name_raw) if isinstance(name_raw, str) else name_raw
            nom_fr   = name.get("fr", "INCONNU")
            nom_nl   = name.get("nl", "INCONNU")

            gps_raw   = record.get("gpscoordinates", "{}")
            gps       = json.loads(gps_raw) if isinstance(gps_raw, str) else gps_raw
            latitude  = gps.get("latitude")
            longitude = gps.get("longitude")

            rows.append((point_id, nom_fr, nom_nl, latitude, longitude))

        offset += limit

        # Si on a reçu moins que la limite, on a tout récupéré
        if len(results) < limit:
            break

    cursor.executemany("""
        INSERT INTO staging_stop_details
        (point_id, nom_fr, nom_nl, latitude, longitude)
        VALUES (?, ?, ?, ?, ?)
    """, rows)

    print(f"  ✔ StopDetails      → {len(rows)} lignes insérées")


# ─────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────
def collecter_tout():
    collected_at = datetime.now()
    print(f"\n[{collected_at}] Début de la collecte...")

    conn   = pyodbc.connect(CONNECTION)
    cursor = conn.cursor()

    collecter_waiting_times(cursor, collected_at)
    collecter_vehicle_positions(cursor, collected_at)

    conn.commit()
    conn.close()
    print("  ✔ Collecte terminée !\n")


if __name__ == "__main__":
    collecter_tout()
