# Repper

Wiederholungszählung aus Smartphone-Beschleunigungsdaten auf dem Gewichtsblock.
Geschwindigkeitsdomäne, nach Viecelli et al. 2020 (`10.1371/journal.pone.0235156`).

Enthalten: die Pipeline in Python, ein Port derselben Pipeline in JavaScript für den
Live-Zähler im Browser, ein Generator für synthetische Sätze mit Ground Truth, Tests
für beide Implementierungen, ein HTTPS-Server für den Handy-Prototyp.

Abhängigkeiten: Python 3.10+ mit numpy. Node (nur für den JS-Test). Sonst nichts.

## Branches

`main` enthält **nur das Verfahren aus dem Paper**: Jeder Peak in der Geschwindigkeit ist
eine Wiederholung, nichts wird abgewogen. Das zählt auch mit, was keine Wiederholung ist
— das Hochnehmen des Blocks in die Startposition, oder eine Wiederholung, die nur halb
hochkommt (siehe `TestKnownLimits`). Dafür ist es klein, nachvollziehbar und auf sauberen
Sätzen zuverlässig.

Alles, was darüber hinausgeht, liegt auf eigenen Branches und wird dort an echten Daten
geprüft, bevor es hier landet:

| Branch | Inhalt |
|---|---|
| `full` | Bewegungsumfang je Satz, Selbstkorrektur, lokale Ruhe-Prüfung, vier Varianten nebeneinander, Live-Parameter, Watch-App mit Aufnahmemodus |
| `baseline` | wie `full`, zusätzlich ein Schalter zurück auf das reine Paper-Verfahren |

---

## Drei Korrekturen zum Handout

**1. Die Rohdaten sind nicht veröffentlicht.** Beide Dataverse-Datensätze
(`10.7910/DVN/R3ZKYH`, 1,9 MB; `10.7910/DVN/A6QHLF`, 0,6 MB) enthalten je eine
einzige Tabelle mit **Phasendauern in Millisekunden** — pro Proband, Maschine, Satz und
Kontraktion, ausgewertet von zwei Videoratern und zwei Smartphones. Kein
Beschleunigungssignal, keine Zeitreihe. Auch im Paper ist kein Code-Repository verlinkt,
nur der Pseudocode in S1. Schritt 1 des Vorschlags — "Pipeline nachbauen und die 0,16 %
am Schreibtisch reproduzieren" — ist mit diesen Dateien nicht durchführbar.

Was die Daten hergeben, ist die reale Kadenzverteilung. Die wird hier genutzt, um
Schwellenwerte zu setzen und um synthetische Signale realistisch zu machen
(`scripts/reference_stats.py`, `src/repper/synth.py`).

**2. `acceleration` ohne Gravitation zerstört den Algorithmus.** Der Vektorlängen-Trick
funktioniert nur mit dem *rohen* Beschleunigungssignal:

```
f = a_Gerät − g⃗   →   |f| = g + a_Achse       (Achse parallel zur Schwerkraft)
```

Der Betrag enthält das Vorzeichen der Bewegungsrichtung — deshalb ist die Orientierung
des Handys egal. Zieht man die Gravitation vorher ab (`userAcceleration`,
`DeviceMotionEvent.acceleration`), liefert der Betrag `|a|` nur noch den Absolutwert.
Das Integral läuft dann monoton weg statt um Null zu schwingen, und es gibt keine Peaks
mehr zu finden. Also `accelerationIncludingGravity` bzw. `CMAccelerometerData`, und den
Gravitationsoffset erst nach der Betragsbildung abziehen.

Für Daten, die nur gravitationsfrei vorliegen, gibt es `gravity_removed=True` — dann
wird die Achse mit der größten Auslenkung genommen und die Orientierungsunabhängigkeit
ist weg.

**3. Der Mindestabstand muss unter 0,84 s.** Das Handout rechnet mit 2–4 s pro
Wiederholung. Die schnellste Wiederholung in den Referenzdaten dauert **1,44 s**
(2020er Studie, 9 Maschinen, 60 % 1RM) bzw. **0,84 s** (2021er Tempostudie). Default
hier: `min_rep_s = 0.6`.

---

## Ergebnisse

Validierung gegen synthetische Sätze mit bekannter Ground Truth — 9 Maschinen × 5 Sätze
× 10 Wiederholungen pro Tempostufe, Kadenzen aus den Referenzverteilungen gezogen:

| Tempo | Precision | Recall | F | Fehlerrate |
|---|---|---|---|---|
| selbstgewählt (60 % 1RM) | 1,0000 | 1,0000 | 1,0000 | 0,00 % |
| schnell (~1 s/Wdh.) | 1,0000 | 1,0000 | 1,0000 | 0,00 % |
| langsam (~8 s/Wdh.) | 1,0000 | 1,0000 | 1,0000 | 0,00 % |

Zeitfehler der Wiederholungserkennung: Bias ≈ 0,00 s, LoA ±0,05 s.

Bei 60 Hz (Browser statt Core Motion) bleiben normales und schnelles Tempo bei F = 1,0000;
langsames Tempo fällt auf F = 0,9933 (0,67 % Fehler, 4 FP / 2 FN von 450). Die 100 Hz
der nativen App sind also nicht egal, aber auch bei 60 Hz liegt der Fehler im Bereich
der Videoreferenz.

**Diese Zahlen sind kein Ersatz für die 0,16 % aus dem Paper.** Sie sagen, dass die
Pipeline-Logik korrekt ist — nicht, dass sie am echten Gerät genauso trifft. Das
synthetische Signal enthält Sensorrauschen, Bias-Drift, Zeitstempel-Jitter, Dropouts,
doppelte Zeitstempel und Stoßtransienten, aber kein Seilspiel, keine Blockresonanz und
keine echte Körperbewegung. Der ehrliche Vergleich kommt erst mit Videoreferenz im
Studio.

Die Phasengrenzen sind schwächer als die Zählung: die konzentrische Phase wird
systematisch um ca. +0,2 bis +0,3 s überschätzt (Nulldurchgänge auf dem geglätteten
Signal). Gleiche Richtung wie der im Paper berichtete Bias, aber größer.

---

## Nutzung

Referenzdaten laden und Kadenzstatistik ansehen:

```bash
python3 scripts/fetch_reference.py && python3 scripts/reference_stats.py
```

Tests (Python-Pipeline, dann JS-Port gegen dieselben Fixtures):

```bash
python3 test/test_pipeline.py && node test/js_parity.mjs
```

Validierungssweep:

```bash
python3 scripts/validate_synthetic.py --sets 5 --fs 60
```

Web-Prototyp auf dem Handy (HTTPS ist Pflicht, self-signed Zertifikat wird beim ersten
Start erzeugt):

```bash
python3 scripts/serve.py
```

Die ausgegebene `https://<LAN-IP>:8443` auf dem iPhone öffnen, Zertifikatswarnung
akzeptieren, **Start** drücken, Bewegungszugriff erlauben. Der Zähler läuft live, darunter
Roh- und Geschwindigkeitssignal mit markierten Peaks. **Export CSV** schreibt die
Rohaufnahme.

Aufnahme nachträglich auswerten:

```bash
python3 -m repper.cli recordings/legpress_set1.csv --fs 60 --verbose
```

---

## Aufbau

```
src/repper/pipeline.py   9-stufige Pipeline, reines numpy
src/repper/synth.py      synthetische Sätze mit Ground Truth
src/repper/io.py         CSV/JSON-Aufnahmen laden
src/repper/cli.py        python3 -m repper.cli <datei>
web/pipeline.js          JS-Port + RepCounter (Streaming)
web/index.html           Live-Zähler, Plots, CSV-Export
scripts/                 fetch_reference, reference_stats, validate_synthetic,
                         make_fixtures, serve
test/                    Python-Tests, JS-Paritätstest, Fixtures
```

Pipeline: Vektorlänge → Hampel → Zeitstempel bereinigen und äquidistant interpolieren →
Gravitationsoffset (Median) → einfach integrieren → Polynom-Detrend (Ordnung nach Länge) →
Moving Average → Peak-Detection (Mindestabstand + Prominenz) → Phasen über
Nulldurchgänge.

Zwei Abweichungen vom Paper, beide empirisch begründet:

- **Gravitationsabzug als konstanter Median**, nicht als gleitende Basislinie. Eine
  gleitende Basislinie ist ein Hochpass; mit 4-s-Fenster kostet sie bei 8-s-Wiederholungen
  37 % F-Score, weil das Ripple falsche Peaks erzeugt. Die Drift erledigt der Polynomfit
  in der Geschwindigkeitsdomäne.
- **Detrend-Ordnung nach Aufnahmelänge** (`auto_detrend_order`, eine Ordnung je 30 s,
  Minimum 2). Order 2 stammt vom Live-Zähler, der nie mehr als 60 s sieht; offline geht
  ein ganzer Satz auf einmal hinein, und über drei Minuten folgt die Parabel der
  Integrationsdrift nicht mehr — die Wiederholungen sitzen auf der Restschräge und
  verlieren ihre Prominenz. Gemessen an einem 189-s-Satz mit 52 Wiederholungen: Order 2
  zählt 49, dasselbe letzte Drittel allein gerechnet alle 10 seiner Tipps, Order 6 über
  den ganzen Satz alle 52. Alles unter 60 s bleibt bei Order 2, damit Offline-Pipeline
  und Live-Zähler auf jedem Fenster, das der Live-Zähler sieht, identisch rechnen.
- **Ruhe-Gate**: Die Prominenzschwelle ist relativ zur Signalamplitude, also würde ein
  still liegendes Handy sein eigenes Rauschen zu "Wiederholungen" hochskalieren. Das
  Verhältnis von geglätteter Komponente zu Residuum trennt Bewegung von Rauschen
  unabhängig von Tempo und Last (`min_snr`, Default 0,5).

Der Live-Zähler im Browser hat zusätzlich: 60-s-Analysefenster (kürzere Fenster zerlegen
langsame Wiederholungen), Frontier-Logik gegen Doppelzählung bei wandernden
Peak-Positionen, und ein Peak muss in zwei aufeinanderfolgenden Analysen auftauchen,
bevor er zählt (ein einzelner Stoß gegen den Block überlebt das nicht).

---

## Was noch fehlt

1. **Echte Aufnahmen mit Videoreferenz.** Ohne die sind alle Zahlen oben synthetisch.
   Drei Maschinen, parallel gefilmt, Kinovea zur Annotation.
2. **Schwellenwerte gegen echte Daten** nachziehen — `min_rep_s`, `prominence_frac`,
   `min_snr` sind an synthetischen Signalen gesetzt.
3. **Phasengrenzen** verbessern (der +0,2 s Bias der konzentrischen Phase).
4. **Swift**, erst wenn der Prototyp im Studio trägt. Core Motion liefert 100 Hz statt
   der ~60 Hz im Browser und gleichmäßigere Zeitstempel; `CMAccelerometerData` nutzen
   (Rohbeschleunigung inkl. Gravitation), nicht `deviceMotion.userAcceleration`.

Lizenz der Referenzdaten: CC-BY 4.0, Zitierung erforderlich.

---

## iOS-App

`ios/` enthält zwei Apps in einem Xcode-Projekt — die iPhone-App und eine Watch-App, die
darin eingebettet mitinstalliert wird. Einrichtung: [ios/SETUP.md](ios/SETUP.md).

```
ios/Shared/        Signal, RepCounter, Demo-Signal, Watch-Link — beide Targets
ios/Repper/        iPhone-App (SwiftUI, Core Motion, CSV-Export)
ios/RepperWatch/   Watch-App (Spiegel-Modus und eigenständiges Zählen)
ios/Tests/         Paritätstest gegen dieselben Fixtures wie Python und JS
```

Die iPhone-App zeichnet jeden Satz auf und zählt live mit. Während des Satzes markieren
Tipps die echten Wiederholungen: obere Bildschirmhälfte für den oberen Umkehrpunkt, ein
Streifen darunter für den unteren. Beide zusammen klammern jede Wiederholung ein, womit
neben der Zählung auch die Phasendauern eine Referenz bekommen. Die letzten zehn Sätze
landen samt Rohsignal im Verlauf — auch wenn danach Reset gedrückt wird.

Der Auswerteweg dazu:

```bash
python3 scripts/evaluate_exports.py ~/Downloads/repper           # Zählung bewerten
python3 scripts/evaluate_exports.py ~/Downloads/repper --sweep   # Parametersuche
```

`--sweep` fährt die Python-Pipeline offline über die Rohsignale und sagt, welche
Schwellenwerte an *deinen* Sätzen am besten getroffen hätten. Das ist der Weg von
Studioaufnahmen zu besseren Voreinstellungen.

Die Watch-App kann zweierlei: **Handy zählt** — das iPhone liegt auf dem Block, die Uhr
zeigt den Zähler und tickt haptisch pro Wiederholung, Start/Stop/Reset gehen von beiden
Seiten. **Uhr auf Block** — die Uhr wird abgeschnallt, liegt selbst auf dem Block und
zählt allein, ohne Handy. Dafür startet sie eine `HKWorkoutSession`, sonst hält watchOS
die App an, sobald das Handgelenk sinkt.

**Aufnahmemodus.** Die Uhr kann Bewegung mitschreiben statt zählen: `userAcceleration`,
Quaternion der Lage und Drehrate mit 100 Hz, dazu die von Hand eingetragene
Wiederholungszahl und die Maschine. Die Datei geht ans iPhone und wird am Rechner
ausgewertet:

```bash
python3 scripts/analyze_wrist.py ~/Downloads/repper --sweep
```

Der dazugehörige Detektor steht in [src/repper/wrist.py](src/repper/wrist.py): Lage
anwenden → Beschleunigung ins Weltsystem drehen → je Achse integrieren und entdriften →
Betrag der Geschwindigkeit. Warum das am Handgelenk nötig ist, zeigt
`scripts/wrist_prototype.py` an simulierten Armbewegungen:

| Bewegungsebene | wahr | Stack-Zähler | Speed-Zähler |
|---|---|---|---|
| senkrecht (Curl) | 10 | 10 | 10 |
| 45° schräg | 10 | 10 | 10 |
| 75° schräg | 10 | **4** | 10 |
| waagerecht (Fly) | 10 | **5** | 10 |

Nicht die Drehung der Uhr bricht dem Stack-Verfahren das Genick — der Betrag `|f|` ist
drehungsinvariant — sondern die **Richtung**: Bei waagerechter Bewegung ist
`|f| = sqrt(g² + a²) ≈ g + a²/2g`, also das quadrierte, gleichgerichtete und um den Faktor
zwanzig geschrumpfte Signal.

Noch nicht enthalten: Zählen mit der Uhr **am Handgelenk** in Echtzeit. Der Vektorlängen-Trick setzt eine
starre, eindimensionale Bewegung entlang der Schwerkraftachse voraus; ein rotierendes
Handgelenk auf gekrümmter Bahn verletzt beides.

Der Zähler dort ist ein Port derselben Pipeline. Er wird gegen dieselben Fixtures
geprüft wie Python und JavaScript:

```bash
swiftc -O ios/Shared/Signal.swift ios/Shared/RepCounter.swift \
       ios/Tests/run_parity.swift -o /tmp/repper-parity && /tmp/repper-parity
```

Alle drei Implementierungen liefern auf allen acht Fixtures identische Zählungen.
