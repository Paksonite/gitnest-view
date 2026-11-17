# Backendy serwerów: Forgejo/Gitea, GitLab, GitHub

## Zasada

Aplikacja ma jeden model danych, ten z Forgejo (`ForgeModels.swift`): repozytorium,
pull request, review, run, job, check. Każdy rodzaj serwera ma klienta, który
tłumaczy swoje API na ten model. Widoki i `AppModel` nie wiedzą, z jakim
serwerem rozmawiają; pytają protokół `ForgeService` (`App/Forge/ForgeService.swift`).

| Klient | Serwery | Uwierzytelnianie | API |
|---|---|---|---|
| `ForgejoClient` | Forgejo, Gitea | `Authorization: token …` | `/api/v1` |
| `GitHubClient` | github.com, GitHub Enterprise Server | `Authorization: Bearer …` | `api.github.com` albo `/api/v3` |
| `GitLabClient` | GitLab self-hosted, gitlab.com | `PRIVATE-TOKEN: …` | `/api/v4` |

## Rodzaj serwera przy podłączaniu

`ForgeAccount.kind` zapisuje rodzaj; konto bez niego (sprzed tej zmiany) to Forgejo.
W kreatorze i w Ustawieniach → Servers jest przełącznik **Find out / Forgejo /
GitHub / GitLab**. Przy „Find out" aplikacja pyta o rzeczy, na które odpowiada
tylko jeden rodzaj serwera (`AppModel.detectKind`):

1. nazwa hosta: `github.com`, `*.ghe.com` → GitHub; `gitlab.com` → GitLab;
2. `/api/v1/version` z polem `version` → Forgejo/Gitea;
3. `/api/v4/version` (bez tokenu GitLab odpowiada 401) → GitLab;
4. `/api/v3/meta` z `installed_version` → GitHub Enterprise.

Od rodzaju zależą: strona tworzenia tokenu, opis potrzebnych uprawnień, sprawdzanie
uprawnień tokenu i nazwa użytkownika dla gita po HTTPS (`x-access-token` na GitHubie,
`oauth2` na GitLabie, login na Forgejo).

## Jak pojęcia przechodzą na siebie

| W aplikacji | Forgejo | GitHub | GitLab |
|---|---|---|---|
| Workspace | organizacja | organizacja | grupa najwyższego poziomu (z projektami podgrup) |
| Repozytorium | repo | repo | projekt; właściciel = pełna ścieżka grupy |
| Pull request, numer | PR, `number` | PR, `number` | merge request, `iid` |
| Review „approve" | review APPROVED | review APPROVE | approval |
| Review „request changes" | REQUEST_CHANGES | REQUEST_CHANGES | komentarz i wycofanie własnej akceptacji (API nie ma tego stanu) |
| Checki commitu | commit statuses | commit statuses + check runs | joby pipeline'ów (`commits/:sha/statuses`) |
| Run | Actions run | Actions workflow run | pipeline (`source` → zdarzenie) |
| Job, kroki | job z krokami | job z krokami | job; kroków brak, log w całości |
| Log na żywo | Range na logu joba | dopiero po zakończeniu joba | `trace` z Range |
| Uruchom ręcznie | workflow_dispatch z inputami | workflow_dispatch z inputami | nowy pipeline, inputy jako zmienne CI/CD |
| Powiadomienia | notifications | notifications | to-dos |
| Zmienne / sekrety | variables / secrets | variables / secrets | zmienne CI/CD; masked/hidden = sekret |

## Czego nie ma po drugiej stronie

- **GitHub:** „Update branch" tylko merge'em (rebase → komunikat); log joba
  dopiero po jego zakończeniu; brak logu pojedynczego kroku.
- **GitLab:** „Update branch" tylko rebase'em; brak „request changes" w API;
  wymagane akceptacje tylko w płatnych planach (Free: brak liczby); brak kroków joba.
- **Forgejo 16:** jak dotąd: bez API ponownego uruchamiania.

Gdy serwer czegoś nie umie, klient rzuca `ForgeError.rejected` z jednym zdaniem,
co zrobić zamiast tego; widok pokazuje je jak każdą odmowę serwera.

## Testy

- `Tests/LiveProviderTests.swift`: GitHub tylko odczyt (`GNV_GITHUB_TOKEN`,
  `GNV_GITHUB_REPO`); GitLab odczyt i zapis na labie (`GNV_GITLAB_HOST`,
  `GNV_GITLAB_TOKEN`, `GNV_GITLAB_REPO`); tłumaczenia stanów i kształtów bez sieci.
- Lab GitLab: `gitlab.k8s-t01.trch.pl` (namespace `trch-gitlab` na klastrze
  testowym), GitLab CE z jednym podem.

## Dalej

- Słownictwo w interfejsie: „merge request" zamiast „pull request" na GitLabie
  (`ForgeKind.pullName` jest gotowe, widoki jeszcze mówią „pull request").
- Wejścia (`spec:inputs`) pipeline'ów GitLaba w oknie „Run".
- GitHub: logi kroków z sekcji `##[group]` w logu joba.
