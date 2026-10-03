# Datenschutzerklärung für Sous

**Stand: 3. Oktober 2026**

## 1. Verantwortlicher

Kevin Raddatz
E-Mail: kevin@raddatz.me

## 2. Das Wichtigste zuerst

Sous kommt ohne Server aus. Es gibt kein Nutzerkonto, keine Anmeldung und
keinen Dienst, an den die App Daten sendet. Deine Rezepte, Einkaufslisten und
Essenspläne liegen auf deinem Gerät und – wenn du iCloud nutzt – in deinem
eigenen privaten iCloud-Bereich, auf den ich als Entwickler keinen Zugriff
habe. Die App enthält keine Analyse-, Werbe- oder Tracking-Bibliotheken.
Einmal am Tag fragt Sous bei Apple nach einer neuen Fassung des
Zutatenkatalogs; dabei sendet die App nichts von dir (Abschnitt 5).

## 3. Daten auf deinem Gerät

Alles, was du in Sous anlegst, wird lokal gespeichert:

- Rezepte samt Zutaten, Zubereitungsschritten und Bildern
- Einkaufslisten und die Zuordnung von Zutaten zu Supermärkten
- Essenspläne und Kochprotokolle
- dein Zutatenkatalog mit eigenen Schreibweisen und Varianten
- Einstellungen der App

Diese Daten verlassen dein Gerät nur auf den in Abschnitt 4 und 6
beschriebenen Wegen. Ich erhalte davon nichts.

## 4. iCloud-Synchronisation

Wenn du auf deinem Gerät bei iCloud angemeldet bist, gleicht Sous deine Daten
über CloudKit zwischen deinen Geräten ab. Die Daten liegen dabei in der
**privaten Datenbank deines eigenen iCloud-Accounts**. Verantwortlich für
diese Verarbeitung ist Apple im Rahmen deines iCloud-Vertrags; ich habe
weder Zugriff auf die Inhalte noch auf die Information, ob du die
Synchronisation nutzt.

Damit Änderungen zeitnah auf deinen anderen Geräten ankommen, verschickt
CloudKit stille Push-Nachrichten über Apples Push-Dienst. Auch diese
Zustellung findet ausschließlich zwischen deinem Gerät und Apple statt.

Ohne iCloud-Anmeldung funktioniert Sous vollständig, dann allerdings nur auf
dem jeweiligen Gerät.

Apples Datenschutzrichtlinie: https://www.apple.com/legal/privacy/de-ww/

## 5. Aktualisierungen des Zutatenkatalogs

Der Zutatenkatalog – Zutaten und ihre Schreibweisen, Gewichte pro Stück oder
Löffel, Gänge im Supermarkt und die Nährwerte aus dem
Bundeslebensmittelschlüssel – wird laufend verbessert. Damit Verbesserungen nicht auf das
nächste App-Update warten müssen, schaut Sous höchstens einmal am Tag nach,
ob es eine neuere Fassung gibt, und lädt sie gegebenenfalls herunter. Sie
gilt ab dem nächsten Start der App.

Die Fassung liegt als öffentliche Datei im CloudKit-Container von Sous bei
Apple, nicht auf einem eigenen Server. Die App liest sie nur; sie sendet
dabei weder Rezepte noch andere Inhalte, keine Kennung und nichts über deine
Nutzung. Das funktioniert auch ohne iCloud-Anmeldung. Wie bei jedem Abruf
im Internet sieht Apple die IP-Adresse deines Geräts; ich erhalte keine
Information darüber, wer oder wie viele Geräte nachsehen.

Der Katalog entsteht öffentlich: Jede Änderung ist in der Versionsgeschichte
des Quellcodes nachzulesen. Einstellungen → Zutatenkatalog zeigt, welche
Fassung die App gerade verwendet, und verlinkt diese Geschichte.

<!--
App Store privacy label: the daily read collects nothing, so it needs no
entry. "Other User Content" (app functionality, not linked to the user once
the creator id is dropped) arrives only with phase 10, when adjustments can
be shared through CatalogSubmission records — together with an entry in the
PrivacyInfo.xcprivacy files and a paragraph here.
-->

## 6. Einen Haushalt teilen

Du kannst andere Personen in deinen Haushalt einladen. Technisch geschieht
das über eine CloudKit-Freigabe: Du verschickst einen Einladungslink über
einen Weg deiner Wahl, und wer ihn annimmt, sieht die geteilten Rezepte,
Einkaufslisten und Pläne und kann sie ändern.

Die Freigabe verwaltet Apple in deinem iCloud-Account. Ich erfahre nicht, ob
du teilst, mit wem, oder was geteilt wird. Wen du einlädst, entscheidest
allein du; die Einladung kannst du in der App jederzeit zurücknehmen.

## 7. Rezepte aus dem Web importieren

Übergibst du Sous eine Internetadresse – über die Teilen-Funktion, den
Import-Dialog oder einen `sous://`-Link – ruft die App **diese Seite direkt
auf**, ohne Umweg über einen Server von mir. Ausgelesen werden nur die
strukturierten Rezeptdaten der Seite (schema.org/Recipe im JSON-LD-Format)
sowie die dort angegebenen Bilder.

Beim Abruf erfährt der Betreiber der aufgerufenen Website – wie bei jedem
Aufruf mit einem Browser – deine IP-Adresse, den Zeitpunkt und technische
Angaben deines Geräts. Auf diese Verarbeitung habe ich keinen Einfluss; es
gelten die Datenschutzbestimmungen der jeweiligen Website.

Rechtsgrundlage: Art. 6 Abs. 1 lit. b DSGVO, da der Abruf die von dir
angeforderte Funktion ist.

## 8. Kalender

Auf Wunsch trägt Sous deinen Essensplan als Termine in deinen Kalender ein.
Dafür fragt die App beim ersten Mal um Erlaubnis. Sous schreibt ausschließlich
in einen eigenen, von der App angelegten Kalender und liest deine übrigen
Termine nicht aus. Du kannst die Erlaubnis in den Systemeinstellungen
jederzeit widerrufen; die Funktion ruht dann.

Rechtsgrundlage: Art. 6 Abs. 1 lit. a DSGVO (Einwilligung).

## 9. Küchentimer und Mitteilungen

Die Timer laufen auf deinem Gerät. Damit ein Timer klingelt, während die App
im Hintergrund ist, benötigt Sous die Erlaubnis für Mitteilungen bzw.
Weckrufe. Es werden keine Mitteilungen von mir versendet – ich habe keine
Möglichkeit dazu.

Rechtsgrundlage: Art. 6 Abs. 1 lit. a DSGVO (Einwilligung).

## 10. Fotos

Ein Bild zu einem Rezept wählst du über die Fotoauswahl des Systems aus. Sous
erhält dabei nur das eine Bild, das du auswählst, und keinen Zugriff auf deine
Fotomediathek.

## 11. Vorschläge auf dem Gerät

Zwei Funktionen – die Erkennung von Mengenangaben beim Import und der
Vorschlag, ob ein Rezept als Abendessen taugt – nutzen Apples
Foundation-Models-Framework. Diese Auswertung läuft **vollständig auf deinem
Gerät**. Es werden keine Rezepttexte an Apple, an mich oder an einen
KI-Anbieter übertragen. Auf Geräten ohne Apple Intelligence sind diese
Funktionen schlicht nicht aktiv.

## 12. Spotlight

Damit du Rezepte über die Systemsuche findest, meldet Sous Titel und
Kurzangaben an den Suchindex deines Geräts. Der Index bleibt lokal.

## 13. Keine Analyse, keine Werbung, kein Tracking

Sous enthält keine Analyse- oder Werbe-SDKs, keinen Absturzmelder eines
Drittanbieters und keine Werbe-Identifikatoren. Es findet kein Tracking im
Sinne des App-Tracking-Transparency-Rahmens statt, weder innerhalb der App
noch über andere Apps oder Websites hinweg.

## 14. Berichte über Apple

Wenn du in den Systemeinstellungen deines Geräts zugestimmt hast, Diagnose-
und Nutzungsdaten mit App-Entwicklern zu teilen, stellt Apple mir
Absturzberichte und aggregierte Nutzungsstatistiken bereit. Diese Daten
erhalte ich ausschließlich in der von Apple aufbereiteten Form; sie enthalten
keine Rezeptinhalte und lassen keinen Rückschluss auf einzelne Personen zu.
Die Zustimmung kannst du jederzeit unter „Einstellungen → Datenschutz &
Sicherheit → Analyse & Verbesserungen" widerrufen.

## 15. Speicherdauer und Löschen

Da ich keine Daten von dir erhalte, speichere ich auch nichts. Deine Daten
löschst du selbst:

- **Auf dem Gerät:** Die App löschen entfernt die lokal gespeicherten Daten.
- **In iCloud:** Unter „Einstellungen → [dein Name] → iCloud → Verwalten"
  lässt sich der Datenbestand von Sous entfernen.
- **Einzelne Rezepte:** Gelöschte Rezepte liegen zunächst im Papierkorb der
  App und lassen sich dort endgültig entfernen.

## 16. Deine Rechte

Dir stehen nach der DSGVO die Rechte auf Auskunft (Art. 15), Berichtigung
(Art. 16), Löschung (Art. 17), Einschränkung der Verarbeitung (Art. 18),
Datenübertragbarkeit (Art. 20) und Widerspruch (Art. 21) zu, ebenso das Recht,
eine erteilte Einwilligung jederzeit zu widerrufen.

In der Praxis läuft eine Auskunftsanfrage an mich ins Leere, weil bei mir
keine personenbezogenen Daten über dich vorliegen. Melde dich trotzdem gern
unter kevin@raddatz.me, wenn du Fragen hast.

Du kannst dich außerdem bei einer Datenschutz-Aufsichtsbehörde beschweren.
Zuständig ist die Behörde deines Wohnsitzes.

## 17. Kinder

Sous richtet sich nicht gezielt an Kinder und erhebt wissentlich keine Daten
von Kindern – die App erhebt überhaupt keine Daten.

## 18. Änderungen dieser Erklärung

Ändert sich die Funktionsweise der App, passe ich diese Erklärung an. Die
jeweils gültige Fassung findest du unter der Adresse, die im App Store bei
Sous hinterlegt ist; das Datum oben nennt den Stand.
