# Accès des agents IA (MCP)

Escale est un **serveur MCP** (Model Context Protocol) local : un agent IA (**Antigravity / `agy`**, **Claude Code / `claude`**,
**Claude Desktop**, **Codex / `codex`**, Cursor, Hermes…) peut agir sur vos hôtes SSH déjà enregistrés dans Escale.
Par défaut, l'agent n'utilise que les connexions déjà ouvertes ; une option explicite permet aussi d'autoriser
l'ouverture de la connexion SSH à la demande (en réutilisant vos clés / secrets Trousseau configurés dans Escale).

## Activer et connecter vos outils IA

1. Ouvrez la fenêtre **Agents IA (MCP)** depuis :
   - la barre d'outils principale (**Agents IA**),
   - le volet latéral **Outils › Agents IA (agy, Claude, Codex)…**,
   - ou le menu **Présentation › Accès des agents (MCP)…**.
2. Cliquez sur **Configurer** en face de votre outil IA (active aussi le serveur MCP si nécessaire) :

| Outil IA | Fichier configuré (écriture atomique non destructive) |
|---|---|
| Antigravity (`agy`) | `~/.gemini/config/mcp_config.json` (`mcpServers.escale`) |
| Claude Code (`claude`) | `~/.claude.json` (`mcpServers.escale`, transport `stdio`) |
| Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` (`mcpServers.escale`) |
| Codex (`codex`) | `~/.codex/config.toml` (`[mcp_servers.escale]`) |

3. Dans la section **Hôtes SSH et autorisations** (ou dans la fiche de chaque hôte, onglet **Avancé**), réglez le niveau d'accès :

| Niveau | Lecture (hôtes, sessions, terminal, fichiers, tunnels) | Actions (connexion, commande, saisie, écriture, tunnel) |
|---|---|---|
| Aucun (défaut) | hôte invisible | — |
| Lecture seule | oui | refusées |
| Actions avec confirmation | oui | panneau de confirmation pour chaque action |
| Actions sans confirmation | oui | sans demander (journalisées) |

4. Optionnel : cochez **« Ouvrir automatiquement la connexion SSH à la demande de l'agent »** pour permettre aux agents de se
   connecter à un hôte exposé même sans onglet ouvert (désactivé par défaut ; demande confirmation sur les hôtes `confirm`).

Des boutons **Copier** permettent aussi de récupérer la commande CLI ou l'extrait JSON/TOML :

```sh
claude mcp add --scope user escale -- /Applications/Escale.app/Contents/MacOS/Escale --mcp
codex mcp add escale -- /Applications/Escale.app/Contents/MacOS/Escale --mcp
```

```json
{ "mcpServers": { "escale": { "command": "/Applications/Escale.app/Contents/MacOS/Escale", "args": ["--mcp"] } } }
```

```toml
[mcp_servers.escale]
command = "/Applications/Escale.app/Contents/MacOS/Escale"
args = ["--mcp"]
```

`Escale --mcp` est un relais stdio vers l'app en service : il ne lance pas Escale et échoue (code 1, message sur stderr)
si l'app est fermée ou l'accès désactivé.

## Outils

| Outil | Nature | Rôle |
|---|---|---|
| `list_hosts` | lecture | hôtes exposés : id, nom, adresse, utilisateur, niveau, état de connexion et drapeau `auto_connect` |
| `connect_host` | action | ouvre (ou réutilise) la connexion SSH d'un hôte exposé quand `auto_connect` est actif (option `open_tab`) |
| `list_sessions` | lecture | panneaux de terminal ouverts sur ces hôtes |
| `read_terminal` | lecture | dernières lignes d'un panneau (écran + historique) |
| `send_input` | action | saisie dans un panneau, comme au clavier (caractères de contrôle permis) |
| `exec` | action | commande non interactive (sans pty, BatchMode, sans X11) : code, stdout, stderr |
| `list_files`, `read_file` | lecture | SFTP (repli shell si le serveur refuse SFTP) ; binaire rendu en base64 |
| `write_file` | action | crée ou remplace un fichier (4 Mio au plus) |
| `list_tunnels` | lecture | tunnels enregistrés de l'hôte et leur état |
| `start_tunnel`, `stop_tunnel` | action | ouvre/ferme un tunnel enregistré (vérifié par sonde du port) |

## Sécurité

- Désactivé par défaut. Aucune écoute TCP : socket Unix `~/Library/Application Support/Escale/agent/mcp.sock` (0600,
  dossier 0700), pair vérifié (même uid, des deux côtés).
- Aucun hôte hors bibliothèque ; protocoles non SSH jamais exposés ; aucun secret dans les réponses (ni mot de passe,
  ni compte Trousseau, ni chemin de clé).
- Par défaut, un agent n'ouvre jamais de connexion : un hôte déconnecté renvoie une erreur (« ouvrez-le dans Escale »).
  Si l'utilisateur active explicitement la connexion à la demande, les hôtes `confirm` demandent confirmation avant
  ouverture et les baux ouverts pour les agents sont libérés à l'arrêt du serveur ou à la désactivation de l'option.
- Les sorties distantes sont des données non fiables (injection de prompt) : c'est la raison du niveau « avec
  confirmation ». Le panneau de confirmation flotte au-dessus des autres apps sans prendre le focus ; une demande
  disparaît si le client se déconnecte.
- Journal en mémoire de chaque appel (outil, hôte, résumé, issue), visible dans la fenêtre des réglages ; jamais écrit
  sur disque, jamais de contenu de fichier ni de sortie.
- Bornes : commande 600 s et 1 Mio de sortie, lecture/écriture 4 Mio, saisie 64 Kio, 8 clients, 16 appels simultanés
  par client, au plus 10 sessions par maître (les appels passent par le plafond commun).
