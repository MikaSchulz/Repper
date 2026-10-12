# App aufs iPhone bringen

Sechs Schritte. Alles außer Schritt 1 dauert Minuten.

## 1. Xcode installieren

App Store → "Xcode" → laden. ~10 GB, das dauert. Danach einmal öffnen und die
Lizenz bestätigen, Xcode lädt dann noch Komponenten nach.

## 2. Projekt öffnen

```bash
open /Users/mikaschulz/Documents/Code/Repper/ios/Repper.xcodeproj
```

## 3. Signierung einstellen

Links im Navigator auf **Repper** (blaues Symbol ganz oben) → Reiter
**Signing & Capabilities**.

- **Team**: "Add an Account…" → mit deiner Apple-ID anmelden → danach dein Name als
  Team auswählen. Kostenloser Account reicht.
- **Bundle Identifier**: steht auf `com.mikaschulz.repper`. Falls Xcode meckert
  ("failed to register bundle identifier"), etwas dranhängen, z. B.
  `com.mikaschulz.repper2`.

## 4. iPhone anstöpseln und starten

iPhone per Kabel an den Mac, am iPhone "Diesem Computer vertrauen" bestätigen.
Oben in Xcode neben dem Projektnamen das iPhone als Ziel wählen, dann **⌘R**.

## 5. Entwickler-App vertrauen

Beim ersten Mal startet die App nicht und iOS zeigt "Nicht vertrauter Entwickler".
Am iPhone: **Einstellungen → Allgemein → VPN & Geräteverwaltung → deine Apple-ID →
Vertrauen**. Dann in Xcode nochmal ⌘R.

## 6. Watch-App

Die Watch-App steckt im selben Projekt und wird beim Ausführen automatisch mit auf die
gekoppelte Uhr geladen. Falls sie dort nicht auftaucht: iPhone-App auf der Uhr in der
Watch-App des iPhones unter "Verfügbare Apps" installieren.

Beim ersten Start fragt sie nach Health-Zugriff. Grund: nur mit einer laufenden
Workout-Sitzung lässt watchOS die App weiterzählen, wenn der Arm unten ist. Ohne diese
Freigabe funktioniert nur der Spiegel-Modus.

Drei Modi, durchschaltbar mit dem Knopf in der Mitte:

- **Handy zählt** — iPhone liegt auf dem Block, die Uhr zeigt den Zähler und tickt bei
  jeder Wiederholung. Start, Stop und Reset wirken in beide Richtungen.
- **Uhr auf Block** — Uhr abschnallen, auf den Block legen, sie zählt allein.
- **Aufnahme** — zählt nichts, schreibt nur mit: Beschleunigung *und Lage* der Uhr mit
  100 Hz. Nach dem Stop fragt die Uhr nach der tatsächlichen Wiederholungszahl und der
  Maschine, dann geht die Datei ans iPhone und landet dort im Verlauf. Von da per AirDrop
  auf den Rechner und rein in `scripts/analyze_wrist.py`.

  Die Aufnahme bleibt auf der Uhr gespeichert, bis das iPhone sie bestätigt hat — ein Satz
  mit dem Handy im Spind geht nicht verloren, die Übertragung wird beim nächsten Öffnen
  der App nachgeholt. Unter dem Zähler steht, wie viele Aufnahmen noch offen sind.

Unter dem Zähler steht der Verbindungszustand (`aktiv · gekoppelt · App auf Uhr ·
erreichbar`). Steht dort etwas anderes, sagt die Zeile direkt, woran es hängt.

## 7. Nutzen

App öffnen → **Start** → Handy auf den Gewichtsblock legen (obenauf, mittig, nicht
zwischen die Platten) → Satz machen. Der Zähler läuft live mit.

Die Lage des Handys ist egal — der Algorithmus rechnet mit dem Betrag des
Beschleunigungsvektors.

---

## Gut zu wissen

**Sieben Tage.** Ohne bezahlten Developer-Account (99 €/Jahr) läuft das Zertifikat
nach 7 Tagen ab, die App startet dann nicht mehr. Fix: iPhone anstöpseln, ⌘R. Dauert
20 Sekunden, Daten bleiben erhalten.

**Mittippen, zwei Zonen.** Während der Satz läuft, ist der Bildschirm in zwei Tippflächen
geteilt:

- **Kurve und Zahl (oben)** — oberer Umkehrpunkt der Wiederholung
- **Streifen darunter, "unten tippen"** — unterer Umkehrpunkt, wo die Last am geringsten
  ist und die nächste Wiederholung anfängt

Zwei verschieden fühlbare Vibrationen, du musst nicht hinschauen. Die Marken erscheinen
als blaue Striche oben und orange Striche unten in der Kurve, die roten Punkte des
Algorithmus dazwischen. Der Pfeil oben rechts nimmt den jeweils letzten Tipp zurück, egal
aus welcher Zone.

Beide Umkehrpunkte zusammen klammern jede Wiederholung ein: unten→oben ist die
konzentrische Phase, oben→unten die exzentrische. Damit werden auch die Phasendauern
überprüfbar, die die App anzeigt — bisher hatten die außerhalb synthetischer Signale gar
keine Referenz.

Gespeichert werden nicht nur die Anzahl, sondern die **Zeitpunkte**. Damit vergleicht
`scripts/evaluate_exports.py` Wiederholung für Wiederholung statt nur Summen:

```
Variante    Treffer  zu viel   fehlt    Versatz
A                10        0       0    -0.31 s
```

"Versatz" ist der typische zeitliche Abstand zwischen Tipp und erkannter Wiederholung —
der Algorithmus markiert die Spitze der Geschwindigkeit, du tippst, wenn du die
Wiederholung spürst. Dazu kommt der Phasenvergleich:

```
Satz                Wdh.   con [s]   ecc [s]   App con   App ecc
2026-08-30T17:12       6      1.50      2.20      1.71      1.97
```

**Nach dem Satz.** Der Zähler bleibt stehen, auch wenn du nicht sofort auf Stop drückst.
Sobald sich zwei Sekunden lang nichts mehr bewegt, wird die Kurve eingefroren und keine
neuen Wiederholungen mehr angenommen — vorher hat der Zähler im Stillstand noch
Phantom-Wiederholungen erfunden und den fertigen Satz verdorben.

**Timer.** Der Knopf "Timer" stellt eine Verzögerung zwischen Start und der ersten
Messung ein (3 bis 15 s), wie der Selbstauslöser einer Kamera. Zeit, das Handy auf den
Block zu legen und in Position zu gehen. Während der Countdown läuft, wird nichts
aufgezeichnet.

**Verlauf.** Die letzten zehn Sätze werden automatisch gespeichert — beim Stop und auch
dann, wenn du versehentlich Reset drückst. Pro Satz: was jede Variante gezählt hat, die
Rohaufnahme, und ein Feld für die tatsächliche Wiederholungszahl. Trag die ein, dann
färben sich passende Varianten grün und daneben liegende orange.

**Vier Varianten gleichzeitig.** Unter der Kurve stehen A bis D — vier Parametersätze,
die denselben Datenstrom parallel auswerten. Tippen schaltet um: die große Zahl, die
Kurve und die roten Punkte gehören dann zu dieser Variante. Umschalten ist verlustfrei,
alle vier haben dieselben Samples gesehen. Kostet etwa 7 ms Rechenzeit pro Variante und
Auswertung, viermal pro Sekunde.

**Parameter live ändern.** Der Regler-Knopf rechts neben den Varianten öffnet die
Einstellungen der gerade gewählten Variante: Mindestabstand, Peak-Prominenz, Mindest-Hub,
Bewertungsverzögerung, Kadenzgrenze, Analysefenster, Ruhe-Schwelle, Sichtungen. Sobald du
den Regler loslässt, läuft der bereits aufgezeichnete Satz komplett neu durch diese
Variante — du siehst den Effekt also am Satz vor dir, nicht erst beim nächsten. Ein
Schieberegler-Symbol am Varianten-Knopf zeigt, dass sie von der Voreinstellung abweicht;
zurücksetzen geht unten in den Einstellungen.

**Großer Start-Knopf.** Unten über die volle Breite — der einzige Knopf, den du triffst,
ohne hinzuschauen. Er wird rot mit "Stop", während aufgezeichnet wird, und orange mit
"Abbrechen", solange der Timer läuft.

**Der Zähler lernt pro Satz und korrigiert sich.** Maßstab ist der zurückgelegte Weg des
Blocks, und der Referenzwert kommt aus dem laufenden Satz — jede Übung hat einen anderen
Hub. Weil bei jedem Durchlauf der ganze Satz neu bewertet wird, darf der Zähler sich
irren und zurücknehmen:

- Der Griff, mit dem du den Block ins Startposition hebst, zählt ein paar Sekunden lang
  als Wiederholung. Sobald zwei echte den Maßstab gesetzt haben, verschwindet er aus der
  Zahl und aus der Kurve.
- Eine letzte Wiederholung, die nur noch halb hochkommt, wird gar nicht erst gezählt.

Die Schwelle liegt bei 65 % des Satz-Medians (`minRomFrac` in `RepCounter.swift`). Zahl
und rote Punkte in der Kurve zeigen immer dasselbe — was gezählt ist, ist markiert.

Preis dafür: der Zähler springt rund eine Sekunde nach dem oberen Umkehrpunkt hoch statt
sofort. Vorher lässt sich der Weg nicht zuverlässig messen.

**Demo-Knopf.** Spielt zehn volle und zwei nur angesetzte Wiederholungen durch dieselbe
Pipeline. Erwartetes Ergebnis: Zähler 10, und die zwei kurzen Hübe in der Kurve bleiben
ohne roten Punkt. Läuft auch im Simulator, der keinen Beschleunigungssensor hat.

**Export CSV → Teilen.** Schreibt die Rohaufnahme raus (AirDrop an den Mac). Damit
lässt sich ein Satz nachträglich am Rechner auswerten:

```bash
python3 -m repper.cli /pfad/zur/repper_38s_10reps.csv --verbose
```

**Kein Berechtigungsdialog.** Der rohe Beschleunigungssensor braucht unter iOS keine
Nutzerfreigabe. Das Display bleibt während der Aufnahme an.

**Stand der Prüfung.** Das Projekt baut mit Xcode 26.5 ohne Warnungen, läuft im
Simulator (iPhone 17 Pro, iOS 26.5) und zählt den Demo-Satz korrekt: 10 von 10, con/ecc
1,7 / 2,1 s. Der Zähl-Algorithmus stimmt außerdem auf allen acht Testaufnahmen exakt mit
der Python- und der JS-Version überein. **Ungetestet ist nur der echte Sensor** — dafür
braucht es dein iPhone und einen Gewichtsblock.

**Rechenlast.** Eine Analyse über das volle 60-Sekunden-Fenster kostet ~7 ms (Release).
Bei vier Auswertungen pro Sekunde sind das wenige Prozent Hauptthread — das Display
bleibt flüssig. Im Debug-Build ist es langsamer, deshalb tickt der Demo-Satz sichtbar
hoch statt sofort fertig zu sein.
