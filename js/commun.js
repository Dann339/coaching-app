// ============================================================
// OUTILS COMMUNS À TOUTES LES PAGES
// ============================================================

const CATEGORIES = ["Poitrine", "Dos", "Épaules", "Biceps", "Triceps", "Quadriceps",
  "Ischio-jambiers", "Fessiers", "Mollets", "Core", "Avant-bras", "Cardio", "Autre"];

// Couleur de chaque catégorie (inspirée des disques olympiques)
const COULEURS_CATEGORIE = {
  "Poitrine": "#d6312b", "Dos": "#1f5fbf", "Épaules": "#e0a400", "Biceps": "#2f8f4e",
  "Triceps": "#6b4fbf", "Quadriceps": "#d6312b", "Ischio-jambiers": "#1f5fbf", "Fessiers": "#c2410c",
  "Mollets": "#2f8f4e", "Core": "#e0a400", "Avant-bras": "#6b4fbf", "Cardio": "#0e7490", "Autre": "#5b6470",
};

// Lire un paramètre de l'adresse, ex. ?client=c1
function parametre(nom) { return new URLSearchParams(location.search).get(nom); }

// Échapper le texte pour l'afficher sans risque dans le HTML
function txt(valeur) {
  return String(valeur ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

function pastille(categorie) {
  const couleur = COULEURS_CATEGORIE[categorie] || COULEURS_CATEGORIE.Autre;
  return `<span class="pastille" style="--c:${couleur}">${txt(categorie)}</span>`;
}

function dateLisible(iso) {
  if (!iso) return "—";
  const d = new Date(iso + "T12:00:00");
  return d.toLocaleDateString("fr-CA", { weekday: "short", day: "numeric", month: "short" });
}
function aujourdhui() {
  const d = new Date();
  return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
}
// Lundi de la semaine d'une date (pour regrouper par semaine)
function lundiDe(iso) {
  const d = new Date(iso + "T12:00:00");
  const jour = (d.getDay() + 6) % 7;
  d.setDate(d.getDate() - jour);
  return d.toISOString().slice(0, 10);
}

// Volume = somme (poids × reps) des séries
function volume(series) {
  return series.reduce((t, s) => t + (Number(s.poids) || 0) * (Number(s.reps) || 0), 0);
}
function poidsMax(series) {
  return series.reduce((m, s) => Math.max(m, Number(s.poids) || 0), 0);
}
function nombre(n) { return Number(n || 0).toLocaleString("fr-CA", { maximumFractionDigits: 1 }); }

// ---------- Vidéos : YouTube, Vimeo ou simple lien ----------
function lienVideoIntegre(url) {
  if (!url) return null;
  let m = url.match(/(?:youtube\.com\/(?:watch\?v=|shorts\/|embed\/)|youtu\.be\/)([\w-]{11})/);
  if (m) return "https://www.youtube-nocookie.com/embed/" + m[1];
  m = url.match(/vimeo\.com\/(?:video\/)?(\d+)/);
  if (m) return "https://player.vimeo.com/video/" + m[1];
  return null;
}
function blocVideo(url) {
  if (!url) return "";
  const integre = lienVideoIntegre(url);
  if (integre) {
    return `<div class="video"><iframe src="${txt(integre)}" title="Vidéo" loading="lazy"
      allow="accelerometer; encrypted-media; gyroscope; picture-in-picture" allowfullscreen></iframe></div>`;
  }
  return `<p><a href="${txt(url)}" target="_blank" rel="noopener">Ouvrir la vidéo</a></p>`;
}

// ---------- Menu du haut (et barre du bas sur téléphone) ----------
// ---------- Mode client : la page est ouverte avec le lien du client (?code=…) ----------
const CODE_CLIENT = parametre("code");
function enModeClient() { return !!CODE_CLIENT; }
function clientDuLien() { return CODE_CLIENT ? db.clients.find(c => c.code && c.code === CODE_CLIENT) : null; }

function afficherMenu(pageActive) {
  if (enModeClient()) {
    // Menu simplifié pour le client : son plan, ses séances, son progrès
    const code = "?code=" + encodeURIComponent(CODE_CLIENT);
    document.body.classList.add("mode-client");
    document.getElementById("menu").innerHTML = `
      <span class="marque"><span class="disque" aria-hidden="true"></span>Coach<b>Plan</b></span>
      <nav aria-label="Menu">
        ${[["client.html", "Mon plan", "plan"], ["seance.html", "Séance", "seance"], ["progression.html", "Mon progrès", "progression"],
           ["client.html", "Nutrition", "nutrition", "&vue=nutrition"]]
          .map(([href, nom, cle, suite = ""]) => `<a href="${href}${code}${suite}" ${cle === pageActive ? 'aria-current="page"' : ""}>${nom}</a>`).join("")}
      </nav>`;
    if (!clientDuLien()) {
      // Code inconnu : on n'affiche rien d'autre
      const main = document.querySelector("main");
      main.querySelectorAll(":scope > *").forEach(el => el.hidden = true);
      main.insertAdjacentHTML("afterbegin", `<div class="vide">Lien invalide. Demande à ton coach de te renvoyer ton lien.</div>`);
    }
    return;
  }
  const liens = [
    ["index.html", "Clients", "clients"],
    ["exercices.html", "Exercices", "exercices"],
    ["programme.html", "Programmes", "programme"],
    ["seance.html", "Séance", "seance"],
    ["progression.html", "Progression", "progression"],
    ["nutrition.html", "Nutrition", "nutrition"],
  ];
  const client = parametre("client");
  const suffixe = client ? "?client=" + encodeURIComponent(client) : "";
  const html = `
    <a class="marque" href="index.html"><span class="disque" aria-hidden="true"></span>Coach<b>Plan</b></a>
    <nav aria-label="Menu principal">
      ${liens.map(([href, nom, cle]) => {
        const avecClient = ["programme", "seance", "progression"].includes(cle) ? suffixe : "";
        const actif = cle === pageActive || (cle === "nutrition" && pageActive === "recettes");
        return `<a href="${href}${avecClient}" ${actif ? 'aria-current="page"' : ""}>${nom}</a>`;
      }).join("")}
    </nav>
    <button class="deconnexion" id="btn-deconnexion" type="button">Déconnexion</button>`;
  document.getElementById("menu").innerHTML = html;
  document.getElementById("btn-deconnexion").onclick = () => Donnees.deconnecter();
}

// ---------- Choix du client (pages Programme, Séance, Progression) ----------
function selecteurClient(idActuel, surChangement) {
  if (enModeClient()) { document.getElementById("choix-client").innerHTML = ""; return; } // le client ne voit que lui-même
  const actifs = db.clients.filter(c => c.actif !== false);
  const options = actifs.map(c => `<option value="${c.id}" ${c.id === idActuel ? "selected" : ""}>${txt(c.nom)}</option>`).join("");
  const conteneur = document.getElementById("choix-client");
  conteneur.innerHTML = `<label class="champ-inline">Client
    <select id="select-client">${options}</select></label>`;
  document.getElementById("select-client").addEventListener("change", e => {
    const url = new URL(location.href);
    url.searchParams.set("client", e.target.value);
    history.replaceState(null, "", url);
    surChangement(e.target.value);
  });
}
function clientCourant() {
  if (enModeClient()) return clientDuLien()?.id || null;
  const id = parametre("client");
  if (id && trouverClient(id)) return id;
  const premier = db.clients.find(c => c.actif !== false);
  return premier ? premier.id : null;
}

// Petit message de confirmation en bas de l'écran
function message(texte) {
  let boite = document.getElementById("toast");
  if (!boite) {
    boite = document.createElement("div");
    boite.id = "toast";
    boite.setAttribute("role", "status");
    document.body.appendChild(boite);
  }
  boite.textContent = texte;
  boite.classList.add("visible");
  clearTimeout(boite._t);
  boite._t = setTimeout(() => boite.classList.remove("visible"), 2200);
}

// ---------- Sous-menu de la section Nutrition ----------
function afficherSousMenuNutrition(actif) {
  document.getElementById("sous-menu").innerHTML = `
    <nav class="onglets" aria-label="Nutrition">
      <a href="nutrition.html" ${actif === "plans" ? 'aria-current="page"' : ""}>Plans nutritionnels</a>
      <a href="recettes.html" ${actif === "recettes" ? 'aria-current="page"' : ""}>Recettes</a>
    </nav>`;
}

// ---------- Calculs nutrition ----------
// Calories par gramme : protéines 4, glucides 4, lipides 9 (fibres non comptées)
const MACROS = [
  { cle: "proteines", nom: "Protéines", kcal: 4 },
  { cle: "lipides", nom: "Lipides", kcal: 9 },
  { cle: "glucides", nom: "Glucides", kcal: 4 },
  { cle: "calories", nom: "Calories", kcal: null },
  { cle: "fibres", nom: "Fibres", kcal: null },
];
// Quantité en grammes (ou kcal), selon l'unité choisie
function quantiteReelle(objectif, poidsLb) {
  const v = Number(objectif?.valeur) || 0;
  if (objectif?.unite === "g/lb") return poidsLb ? v * poidsLb : 0;
  if (objectif?.unite === "g/kg") return poidsLb ? v * poidsLb / 2.2046 : 0;
  return v;
}

// Tempo, RIR et repos d'un exercice du programme, sur une ligne
function detailsExercice(x) {
  const morceaux = [];
  if (x.tempo) morceaux.push(`Tempo ${txt(x.tempo)}`);
  if (x.rir) morceaux.push(`RIR ${txt(x.rir)}`);
  if (x.repos) morceaux.push(`Repos ${txt(x.repos)}`);
  return morceaux.length ? `<p class="details-ex">${morceaux.map(m => `<span>${m}</span>`).join("")}</p>` : "";
}
