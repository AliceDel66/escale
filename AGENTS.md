# Escale

Client SSH natif macOS (sessions, SFTP lateral, tunnels, multi-execution). Plan et decisions : `docs/PLAN.md`.

## Structure
- `Packages/EscaleCore` : logique sans UI (modeles, transport SSH, SFTP, pty, serveur X11 integre). Testee par `swift test`.
  Seule cible C : `CEscaleX11` (remise du socket au serveur Xquartz par Mach).
- `Escale/` : app SwiftUI/AppKit. Le moteur de terminal (SwiftTerm) reste confine a `Escale/Terminal/`.
- Modules M2-M5 et protocoles (`Escale/{SFTP,Tunnels,MultiExec,Macros,Import,Update,Serial,Telnet,VNC,RDP,Monitoring,Colors,MCP}/`) : s'accrochent a l'app uniquement par
  `Escale/Features/AppFeature.swift` (commandes, scenes, menus d'hote), `ConnectionManager.linkObservers`,
  `TerminalSession.inputObservers`, `AppModel.terminalLaunchers`/`externalOpeners` (protocoles) et `--selftest-<module> <dossier>`.
- Interface calquee sur MobaXterm (barre d'outils, volets de la barre laterale, accueil, barre d'etat) : `docs/UI-MOBAXTERM.md`.
- `project.yml` : source du projet Xcode (XcodeGen). `Escale.xcodeproj` est genere, non versionne.

## Commandes
- `scripts/test.sh` : tests du coeur + build de l'app. A lancer avant tout commit.
- `scripts/selftest-{ssh,auth,panes,terminal,sftp,sftp-shell,tunnels,multiexec,macros,import,serial,telnet,vnc,rdp,monitoring,hosteditor,compact,tabs,colors,mcp}.sh` : recettes de l'app contre un sshd local
  (ouvrent une fenetre, sans prendre le focus). Resultats dans `$OUT` (result.json + captures).
  A lancer apres tout changement dans `Escale/`, une a la fois (meme dossier `build/`). Sortie vers un fichier,
  pas `| tail` (le garde-fou `sleep` en arriere-plan garde la pipe ouverte).
- `scripts/release.sh [--skip-notarize]` : build Release Developer ID, notarisation, DMG, appcast (`docs/RELEASE.md`).
- `scripts/publish.sh [--dry-run]` : met la release de `dist/` en ligne (DMG + appcast) sur escale-ssh.vercel.app, verifie en ligne.

## Localisation
Langue de developpement : francais ; anglais en plus, l'app suit la langue du systeme. Catalogue unique `Escale/Resources/Localizable.xcstrings`,
cles = chaines francaises telles qu'ecrites dans le code (litteraux SwiftUI `Text`/`Button`/`Label`/`.help`... deja localisables). Une chaine
non litterale (type `String`, message d'erreur, `NSAlert`) passe par `String(localized: "...")`. Nouvelle chaine : l'ajouter au catalogue
avec sa traduction `en` (Xcode l'y fait apparaitre a la compilation). Ne jamais localiser les commandes, chemins ni valeurs de protocole.

## Invariants
1. Aucun type SwiftTerm hors de `Escale/Terminal/` : tout passe par `TerminalEngine`.
2. Tout client ssh secondaire passe `-o ControlMaster=no -o ProxyCommand=/usr/bin/false`
   (sinon ssh rouvre en silence une connexion quand le maitre refuse la session).
3. Supprimer un socket de controle mort avant `ssh -M`.
4. `ssh -O forward/cancel` renvoie 0 meme en cas de refus : verifier par sonde du port et journal du maitre.
5. Au plus 10 sessions par connexion maitre (MaxSessions par defaut).
6. Chemin de socket de controle court (limite ~104 octets).
7. Aucun secret dans les modeles ni sur disque : references Keychain uniquement.
8. Ne jamais ecrire dans `~/.ssh`.
9. Ne jamais tuer des processus ssh par motif large (`pkill -f "ssh -M"`) : viser un pid ou un chemin propre a la
   session. Un motif large coupe les connexions d'une app en service et fait echouer les tests lances en parallele.
10. Une cle d'hote modifiee est toujours refusee, jamais proposee a l'utilisateur comme simple confirmation.
11. Un secret n'est memorise dans le Keychain qu'apres une connexion reussie ; jamais dans un journal ni un message d'erreur.
12. Un module n'ouvre aucune session sur le maitre sans action de l'utilisateur : SwiftUI evalue le contenu d'un
    `.inspector` meme replie, donc garder sa vue derriere `if visible` (sinon `sessionCount` derive). Le navigateur SFTP
    est le volet « Fichiers » de la barre laterale : `SidebarView` ne le construit que dans la branche `.files`. La barre
    d'etat et la page d'accueil n'affichent que de l'etat deja connu (aucune sonde).
13. Deux lignes exec distinctes : `execArguments` (applications X11, avec ForwardX11) et `batchExecArguments`
    (multi-execution : BatchMode, sans X11). Toute session exec compte dans `sessionCount`.
14. Serveur X11 integre (`Contents/Helpers/EscaleX11.app`, `scripts/x11-bundle.sh`) : demarre seulement a la demande, arrete par
    son pid (jamais par motif), socket dans un dossier prive 0700, aucune ecoute TCP. Le C reste confine a `CEscaleX11`
    (protocole Mach de Xquartz). Changer de version de XQuartz = nouveau SHA-256 + verifier les chaines patchees de `X11.bin`.
    quartz-wm (APSL 2.0) est un client du serveur integre : lance apres lui, arrete par son pid avant lui ; sa licence
    et l'offre de source restent dans `EscaleX11.app/Contents/Resources`.
15. Protocoles non SSH : un tunnel « via SSH » (Telnet, VNC, RDP) n'est ouvert qu'a l'ouverture de l'hote par l'utilisateur,
    verifie par sonde du port et ferme par sa spec (jamais par motif). Telnet ne stocke rien ; un `.rdp` genere ne contient
    jamais de secret et refuse toute valeur avec retour a la ligne ou caractere de controle (injection de cle).
16. Un port serie n'est ouvert qu'une fois par processus (registre par realpath, en plus de `TIOCEXCL`). Les tests serie
    utilisent un pty : BREAK, DTR/RTS et debits non standard restent a verifier sur materiel.
17. Les fixtures de recette ne dependent d'aucun outil Homebrew (PATH systeme seul) : `/usr/bin/openssl` est LibreSSL.
18. Toute valeur d'hote inseree dans une saisie ou une commande (multi-execution, macros) passe par `GroupExecTemplate`
    (echappement shell, un seul passage) : jamais d'interpolation brute.
19. Connexion rapide : la saisie passe par `QuickConnectTarget.parse` (refus du tiret initial, des espaces et caracteres
    de controle) et l'hote est enregistre dans la bibliotheque avant d'etre ouvert ; jamais de session sur un hote hors
    bibliotheque (son secret du Trousseau n'aurait pas de cycle de vie).

20. Coloration de la sortie (`OutputHighlighter`) : n'insère que des SGR (`ESC[3Xm` / `ESC[39m`), ne modifie aucun octet
    du programme, ne touche ni l'intérieur des séquences d'échappement, ni l'écran alternatif, ni le texte déjà coloré.
    Un mot retenu en fin de paquet est rendu sous 8 ms (et aussitôt pour l'écho d'une frappe). Le thème s'applique avant
    le premier octet d'un panneau (`AppModel.paneStartObservers`).
21. Acces des agents IA (MCP, `docs/MCP.md`) : desactive par defaut ; socket Unix 0600 dans un dossier 0700, pair de meme uid
    verifie des deux cotes, aucune ecoute TCP ; `Escale --mcp` relaie seulement (ne lance jamais l'app). Seuls les hotes SSH
    de la bibliotheque avec `agentAccess != .none` sont visibles ; par defaut un agent n'ouvre jamais de maitre (liens deja
    connectes seuls, retenus le temps de l'appel), et si `mcp.autoConnect` est active par l'utilisateur les hotes `confirm`
    demandent confirmation et les baux retenus sont liberes a l'arret ; une action (`MCPOperation.action`) sur un hote
    `confirm` attend l'accord de l'utilisateur et un client deconnecte retire sa demande. Aucun secret dans une reponse ;
    journal en memoire seulement. Une recette n'utilise jamais le socket ni les preferences reels (`ESCALE_MCP_SOCKET`,
    suite de defaults isolee).

## Conventions
- Swift 6, concurrence stricte. Commentaires en francais. Sujets de commit sans accents.
- Recherche : `rg`, jamais `grep`.
