# Plan: kreator pierwszego uruchomienia, konfiguracja integracji, samouczek

Szkic do decyzji. Nic z tego nie jest jeszcze zbudowane; dziś pierwszy ekran
to jeden formularz (serwer, token, folder), a Jirę podłącza się w Ustawieniach.

## 1. Kreator pierwszego uruchomienia

Cel: od instalacji do pierwszego otwartego repo w mniej niż dwie minuty, bez
czytania dokumentacji. Pięć kroków, pasek postępu u góry, „Wstecz" zawsze
dostępne, każdy krok poza pierwszym i drugim można pominąć.

| # | Krok | Co robi użytkownik | Co sprawdza aplikacja |
|---|------|--------------------|-----------------------|
| 1 | Serwer Forgejo | wpisuje adres | czy to Forgejo i jaka wersja (16 i 17 różnią się API); ostrzeżenie przy nieobsługiwanej |
| 2 | Token | klika „Utwórz token" (otwiera stronę tokenów serwera z listą potrzebnych uprawnień), wkleja | każde uprawnienie osobno: repozytoria, organizacje, issues/PR, powiadomienia, zapis; lista z zielonym/szarym znaczkiem i tym, co bez niego nie zadziała |
| 3 | Organizacja | wybiera z listy | liczba repo; ile z nich ma Actions |
| 4 | Folder roboczy | wskazuje folder | ile istniejących klonów rozpoznano po adresie remote; propozycja „Sklonuj resztę" (do pominięcia) |
| 5 | Powiadomienia i integracje | włącza powiadomienia macOS, ikonę w pasku menu, opcjonalnie Jirę | test połączenia z Jirą |

Zasady:

- **Token tylko do odczytu jest pełnoprawnym wyborem.** Krok 2 mówi wprost:
  „z tym tokenem przeglądasz; merge, review i komentarze będą wyszarzone".
- **Pęk kluczy:** przed zapisem tokenu jedno zdanie, że macOS zapyta o zgodę i
  że „Zawsze pozwalaj" oszczędza kolejnych pytań.
- **Błędy w miejscu:** zły adres, certyfikat, VPN, odrzucony token — komunikat
  przy polu, z jednym konkretnym następnym krokiem.
- **Wznowienie:** przerwany kreator wraca na krok, na którym skończono.
- **Ponowne uruchomienie:** Ustawienia → „Uruchom kreator ponownie" (drugi
  serwer, nowy komputer).

Ekran końcowy: trzy rzeczy, które już czekają („2 prośby o review", „3 repo do
pobrania", „1 nieudany pipeline") z przyciskiem do każdej — zamiast pustego
„Gotowe".

## 2. Konfiguracja integracji

Jedno miejsce: Ustawienia → **Integracje**, każda integracja jako karta w tym
samym układzie: stan (połączono jako…, błąd), co aplikacja z niej czyta, co
może zmienić, przyciski „Testuj", „Rozłącz".

- **Forgejo** (wymagane): serwery, sposób klonowania, uprawnienia tokenu
  widoczne po fakcie, przycisk „Zmień token".
- **Jira** (opcjonalna, zbudowana): adres, e-mail, token API. Do dodania:
  wybór projektów lub własny JQL, klucze ticketów rozpoznawane w nazwach
  gałęzi, czy tickety mają trafiać do To do.
- **Edytor i terminal:** który edytor otwiera pliki (dziś zgadywany), który
  terminal.
- **Później, jeśli będą potrzebne:** powiadomienia do Slacka/Teams o nieudanym
  pipeline, drugi serwer Git.

Zasada wspólna: integracja wyłączona nie zostawia śladu w interfejsie; każda
domyślnie tylko czyta, a zapis włącza się osobnym przełącznikiem.

## 3. Samouczek

Trzy warstwy, od najlżejszej:

1. **Podpowiedzi przy pierwszym użyciu** — dymek przy elemencie, gdy
   użytkownik pierwszy raz trafia na ekran (pasek boczny „co wymaga uwagi",
   ⌘K, karta planu Terraform, panel pliku w Resources, To do). Każdy dymek raz,
   z „Nie pokazuj więcej". Bez blokowania ekranu.
2. **Przewodnik „Pierwsze 5 minut"** — uruchamiany z ekranu końcowego kreatora
   i z menu Pomoc. Sześć kroków na prawdziwych danych użytkownika, każdy
   kończy się wykonaniem akcji, nie kliknięciem „Dalej":
   1. znajdź repo przez ⌘K,
   2. przeczytaj plan w otwartym PR,
   3. otwórz zasób w Resources i jego historię,
   4. zrób zmianę: gałąź → commit wybranych linii → push,
   5. otwórz PR w zakładce Pull requests i poproś o review,
   6. zobacz log działającego pipeline'u.
   Kroki 4–5 zapisują na serwerze, więc przewodnik proponuje repo testowe albo
   pozwala je pominąć.
3. **Ściąga** — menu Pomoc → „Skróty i słownik": skróty klawiszowe, znaczenie
   znaczków w pasku bocznym, czym różni się Overview od Pull requests.

Treść w aplikacji po angielsku, jak reszta interfejsu; do decyzji, czy dodać
polski.

## Kolejność i koszt

1. Kreator (kroki 1–4) + sprawdzanie uprawnień tokenu — największy zysk,
   usuwa też dzisiejsze ciche błędy przy zbyt słabym tokenie.
2. Ustawienia → Integracje jako osobna zakładka (przeniesienie Jiry, edytor).
3. Podpowiedzi przy pierwszym użyciu.
4. Przewodnik „Pierwsze 5 minut".

## Otwarte pytania

- Czy token tylko do odczytu ma być w kreatorze opcją równorzędną, czy
  „zaawansowaną"?
- Czy przewodnik ma tworzyć własne repo testowe na serwerze, czy tylko
  wskazywać istniejące?
- Jeden język interfejsu czy dwa?
