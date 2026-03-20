# BRIEF — Ajout de l'historique complet dans la plateforme Validation Posts SAMEDIA

## Contexte

La plateforme `Validation-Posts-SAMEDIA-2026` est un site statique (HTML/JS monofichier) déployé sur Netlify.
Elle permet à l'équipe SAMEDIA de valider, annoter et suivre la publication de posts LinkedIn.

**Fichier cible : `index.html`** (unique fichier à modifier — tout le code JS, CSS et HTML est dedans)

---

## Architecture actuelle — ce qu'il faut connaître avant de toucher au code

### 1. Données statiques → `posts-data.json`
Chargé au démarrage via `fetch()`. Contient les posts (titre, caption, slides, date proposée).
Ne pas modifier ce fichier.

### 2. Données dynamiques → Supabase
**Table existante : `post_validations`**

| Colonne       | Type      | Description                              |
|---------------|-----------|------------------------------------------|
| `post_id`     | text (PK) | ID du post (ex: `sav-scie-1`)            |
| `status`      | text      | `wait` / `ok` / `fix` / `published`     |
| `note`        | text      | Remarque de direction                    |
| `custom_date` | date      | Date de publication modifiée             |
| `updated_at`  | timestamp | Dernière mise à jour                     |
| `updated_by`  | text      | Prénom de l'utilisateur (depuis localStorage `sm_username`) |

Connexion dans le code :
```js
const SUPABASE_URL = 'https://qbwznygaqonscqkibasc.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...'; // déjà dans index.html
const sb = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
```

**Problème actuel** : la table `post_validations` fonctionne en `upsert` sur `post_id` → elle écrase à chaque changement. Aucun historique des changements n'est conservé.

### 3. Cache local → `localStorage`
Toutes les données Supabase sont aussi écrites en localStorage avec les clés `sm_st_<pid>`, `sm_note_<pid>`, `sm_date_<pid>`. C'est un cache de fallback si Supabase est indisponible. Ne pas supprimer ce mécanisme.

### 4. Vues existantes (tabs de navigation)
La barre de navigation contient 4 boutons gérés par `switchView(mode, btn)` :
- `campaigns` (vue par défaut)
- `kanban`
- `planning`
- `mktg`

HTML actuel des onglets :
```html
<button class="vtbtn on" id="vt-campaigns" onclick="switchView('campaigns',this)">☰ Campagnes</button>
<button class="vtbtn" id="vt-kanban"    onclick="switchView('kanban',this)">⊞ Kanban</button>
<button class="vtbtn" id="vt-planning"  onclick="switchView('planning',this)">📅 Planning</button>
<button class="vtbtn" id="vt-mktg"      onclick="switchView('mktg',this)">📈 Plan Mktg</button>
```

---

## Objectif — Ce qu'il faut construire

### A. Nouvelle table Supabase : `post_history`

Créer cette table via l'API Supabase (SQL à exécuter dans le dashboard Supabase ou via `sb.rpc` / REST).

```sql
CREATE TABLE post_history (
  id           bigserial PRIMARY KEY,
  post_id      text        NOT NULL,
  event_type   text        NOT NULL,  -- 'status' | 'note' | 'date'
  old_value    text,                  -- valeur avant le changement (nullable)
  new_value    text,                  -- valeur après le changement
  changed_by   text,                  -- prénom utilisateur (CURRENT_USER)
  changed_at   timestamptz NOT NULL DEFAULT now()
);

-- Index pour les requêtes par post et par date
CREATE INDEX idx_post_history_post_id   ON post_history(post_id);
CREATE INDEX idx_post_history_changed_at ON post_history(changed_at DESC);

-- RLS : lecture et écriture publique (même politique que post_validations)
ALTER TABLE post_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY "anon read"  ON post_history FOR SELECT USING (true);
CREATE POLICY "anon write" ON post_history FOR INSERT WITH CHECK (true);
```

> **Note** : La clé `anon` suffit pour INSERT et SELECT (pas de UPDATE ni DELETE sur cette table — l'historique est immuable).

---

### B. Modifications dans `index.html`

#### B1. Fonction `logHistory(postId, eventType, oldValue, newValue)`

Ajouter cette fonction dans la section `// ══ SUPABASE HELPERS ══` :

```js
async function logHistory(postId, eventType, oldValue, newValue) {
  if (!supabaseReady) return;
  if (oldValue === newValue) return; // pas de changement réel
  try {
    await sb.from('post_history').insert({
      post_id:    postId,
      event_type: eventType,
      old_value:  oldValue ?? null,
      new_value:  newValue ?? null,
      changed_by: CURRENT_USER,
      changed_at: new Date().toISOString()
    });
  } catch (e) {
    console.warn('logHistory failed:', e);
  }
}
```

#### B2. Appels à `logHistory` aux 3 points de changement existants

**Changement de statut** — dans la fonction `setSt(pid, st, btn)` (chercher `upsertToSupabase(pid, {` avec `status`) :
```js
// Avant l'upsert existant, ajouter :
const oldSt = localStorage.getItem('sm_st_' + pid) || 'wait';
logHistory(pid, 'status', oldSt, st);
```

**Changement de note** — dans la fonction `saveNote(pid)` (chercher `upsertToSupabase(pid, { note:`) :
```js
// Avant l'upsert existant, ajouter :
const oldNote = localStorage.getItem('sm_note_' + pid) || '';
logHistory(pid, 'note', oldNote || null, ta.value || null);
```

**Changement de date** — dans la fonction `onDateChange(pid)` (chercher `upsertToSupabase(pid, { custom_date:`) :
```js
// Avant l'upsert existant, ajouter :
const oldDate = localStorage.getItem('sm_date_' + pid) || null;
logHistory(pid, 'date', oldDate, v || null);
```

---

#### B3. Nouvel onglet "Historique" dans la navigation

**Ajouter le bouton** dans la barre de navigation (après le bouton `vt-mktg`) :
```html
<button class="vtbtn" id="vt-history" onclick="switchView('history',this)">🕓 Historique</button>
```

**Ajouter le case dans `switchView`** (dans la fonction existante `switchView(mode, btn)`) :
```js
if (mode === 'history') buildHistory();
```

---

#### B4. Fonction `buildHistory()`

Cette fonction charge et affiche tous les événements de `post_history`, triés par `changed_at DESC`.

```js
async function buildHistory() {
  const container = document.getElementById('main-content'); // conteneur principal existant
  container.innerHTML = '<div style="padding:32px;text-align:center;color:#999">Chargement de l\'historique…</div>';

  if (!supabaseReady) {
    container.innerHTML = '<div style="padding:32px;color:#c00">⚠ Supabase non disponible</div>';
    return;
  }

  try {
    const { data, error } = await sb
      .from('post_history')
      .select('*')
      .order('changed_at', { ascending: false })
      .limit(200);

    if (error) throw error;

    // Construire un index titre des posts depuis POSTS (variable globale chargée depuis JSON)
    const titleIndex = {};
    POSTS.forEach(p => { titleIndex[p.id] = p.title; });

    // Labels lisibles
    const eventLabels = { status: 'Statut', note: 'Note', date: 'Date publi.' };
    const statusLabels = { wait: 'En attente', ok: 'Validé', fix: 'À modifier', published: 'Publié' };

    if (!data || data.length === 0) {
      container.innerHTML = '<div style="padding:48px;text-align:center;color:#999">Aucun événement enregistré.</div>';
      return;
    }

    // Rendu — tableau chronologique
    const rows = data.map(row => {
      const date = new Date(row.changed_at);
      const dateStr = date.toLocaleDateString('fr-FR', { day: '2-digit', month: 'short', year: 'numeric' });
      const timeStr = date.toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' });
      const title = titleIndex[row.post_id] || row.post_id;
      const evLabel = eventLabels[row.event_type] || row.event_type;
      const oldVal = row.event_type === 'status' ? (statusLabels[row.old_value] || row.old_value || '—') : (row.old_value || '—');
      const newVal = row.event_type === 'status' ? (statusLabels[row.new_value] || row.new_value || '—') : (row.new_value || '—');
      const by = row.changed_by || 'anonyme';

      // Pour les notes longues, tronquer l'affichage
      const displayOld = (oldVal.length > 60) ? oldVal.substring(0, 60) + '…' : oldVal;
      const displayNew = (newVal.length > 60) ? newVal.substring(0, 60) + '…' : newVal;

      return `<tr>
        <td style="white-space:nowrap;padding:8px 12px;color:#888;font-size:12px">${dateStr}<br><span style="font-size:11px">${timeStr}</span></td>
        <td style="padding:8px 12px;font-size:13px;font-weight:600;max-width:200px">${title}</td>
        <td style="padding:8px 12px;font-size:12px"><span style="background:#f0f0f0;border-radius:4px;padding:2px 7px">${evLabel}</span></td>
        <td style="padding:8px 12px;font-size:12px;color:#999">${displayOld}</td>
        <td style="padding:8px 12px;font-size:12px">→</td>
        <td style="padding:8px 12px;font-size:12px;font-weight:500">${displayNew}</td>
        <td style="padding:8px 12px;font-size:12px;color:#888">${by}</td>
      </tr>`;
    }).join('');

    container.innerHTML = `
      <div style="padding:24px 32px">
        <h2 style="font-size:18px;font-weight:700;margin:0 0 6px">🕓 Historique des modifications</h2>
        <p style="font-size:13px;color:#888;margin:0 0 20px">${data.length} événement(s) — 200 derniers affichés</p>
        <div style="overflow-x:auto">
          <table style="width:100%;border-collapse:collapse;font-family:inherit">
            <thead>
              <tr style="border-bottom:2px solid #eee;text-align:left">
                <th style="padding:8px 12px;font-size:12px;color:#aaa;font-weight:600">DATE</th>
                <th style="padding:8px 12px;font-size:12px;color:#aaa;font-weight:600">POST</th>
                <th style="padding:8px 12px;font-size:12px;color:#aaa;font-weight:600">TYPE</th>
                <th style="padding:8px 12px;font-size:12px;color:#aaa;font-weight:600">AVANT</th>
                <th style="padding:8px 12px"></th>
                <th style="padding:8px 12px;font-size:12px;color:#aaa;font-weight:600">APRÈS</th>
                <th style="padding:8px 12px;font-size:12px;color:#aaa;font-weight:600">PAR</th>
              </tr>
            </thead>
            <tbody style="font-size:13px">
              ${rows}
            </tbody>
          </table>
        </div>
      </div>`;
  } catch (e) {
    container.innerHTML = `<div style="padding:32px;color:#c00">Erreur chargement historique : ${e.message}</div>`;
  }
}
```

> **Important** : identifier le bon sélecteur pour `container`. Dans le code actuel, le contenu principal est injecté dans un `<div id="content">` ou similaire. Vérifier le `id` exact du conteneur principal dans le HTML et adapter la ligne `document.getElementById(...)` en conséquence.

---

## Contraintes à respecter absolument

1. **Ne pas casser le mécanisme localStorage** — il reste le fallback si Supabase est indisponible.
2. **Ne pas modifier `posts-data.json`** — fichier statique, hors scope.
3. **`logHistory` ne doit jamais bloquer** — wrapper dans `try/catch`, silencieux en cas d'échec.
4. **Les changements de note ne doivent logguer que lors du blur / sauvegarde**, pas à chaque frappe clavier (la fonction `saveNote` utilise déjà un debounce ou est appelée sur `oninput` — vérifier et adapter pour ne logger qu'une fois stabilisée, ou accepter les logs fréquents si l'existant ne debounce pas).
5. **`supabaseReady` doit être `true`** avant tout appel à `logHistory` — la garde `if (!supabaseReady) return` dans la fonction est suffisante.
6. **Le style** de la vue Historique doit être cohérent avec le reste : fond blanc, police système, couleurs de l'UI existante (jaune `#FFE500`, noir `#111`).

---

## Résultat attendu

- Chaque changement de statut, note ou date crée une ligne dans `post_history` sur Supabase.
- Un 5ème onglet "🕓 Historique" apparaît dans la navigation.
- Cet onglet affiche un tableau des 200 derniers événements (date, post, type, ancienne valeur, nouvelle valeur, auteur).
- L'historique est partagé entre tous les utilisateurs de la plateforme (car il vient de Supabase).
- Aucune régression sur les vues existantes (Campagnes, Kanban, Planning, Plan Mktg).
