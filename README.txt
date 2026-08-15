Appearance
==========

APPEARANCE.R4X ist die Desktop-Einstellungsanwendung fuer die Darstellung
von R4OS. Sie wird ueber Start -> Settings -> Appearance geoeffnet.

Version 0.1.0 verwaltet die Desktop-Hintergrundfarbe. Die Anwendung bietet
eine Vorschau, 16 klassische Farbfelder und eine direkte Eingabe als sechs
hexadezimale RGB-Ziffern. Apply speichert, OK speichert und schliesst,
Cancel schliesst ohne weitere Aenderung.

Die Einstellung bleibt im bestehenden Schluessel DESKTOP_BG unter
C:\R4OS\CONFIG\DESKTOP.R4S. Nach erfolgreichem atomarem Speichern meldet
die Anwendung die neue Farbe ueber den vorhandenen GUI-Revisionskanal an
den Desktop. Der Desktop laedt daraufhin genau diese Konfiguration neu.
Es gibt weder einen zweiten Konfigurationsort noch periodisches Dateipolling
und keinen Appearance-Zustand im Kernel.

Selbsttest:
  APPEARANCE.R4X /SELFTEST

Der Selbsttest prueft RGB- und Benachrichtigungsformat sowie die atomare
Aktualisierung von DESKTOP_BG unter Erhalt eines fremden Schluessels.
