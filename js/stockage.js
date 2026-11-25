// ============================================================
// STOCKAGE DES DONNÉES — en ligne avec Supabase
//
// Les pages travaillent toujours avec « db » (toutes les données en mémoire)
// et appellent enregistrer() après un changement.
// Ce fichier envoie ensuite à Supabase SEULEMENT ce qui a changé
// (un client, une séance, un plan…), jamais toute la base d'un coup.
//
// Deux façons d'ouvrir l'app :
//  - le coach, connecté avec son courriel (page connexion.html) : voit tout ;
//  - le client, avec son lien (?code=…) : voit et enregistre seulement SES données.
// ============================================================

// Chaque liste de « db » et sa table dans Supabase
const TABLES = {
  clients: "clients",
  exercices: "exercices",
  programmes: "programmes",
  seances: "seances",
  recettes: "recettes",
  plansNutrition: "plans_nutrition",
};
// Ce que le client a le droit d'enregistrer avec son lien
const TABLES_CLIENT = ["seances", "programmes"];

let db = { clients: [], exercices: [], programmes: [], seances: [], recettes: [], plansNutrition: [], reglages: {} };
let sb = null;                 // le client Supabase
let instantane = {};           // dernière version envoyée de chaque élément, pour savoir ce qui a changé
let fileEnvoi = Promise.resolve();
let envoisEnCours = 0;

const codeDuLien = new URLSearchParams(location.search).get("code");
// Cloudflare peut afficher les pages sans « .html » (ex. /connexion) : on accepte les deux
const pageConnexion = /\/connexion(\.html)?$/.test(location.pathname);

function chargerScript(src) {
  return new Promise((ok, erreur) => {
    const s = document.createElement("script");
    s.src = src; s.onload = ok;
    s.onerror = () => erreur(new Error("Impossible de charger " + src + ". Vérifie la connexion internet."));
    document.head.appendChild(s);
  });
}

function afficherErreurGlobale(texte) {
  const boite = document.createElement("div");
  boite.className = "erreur-globale";
  boite.setAttribute("role", "alert");
  boite.textContent = texte;
  document.body.prepend(boite);
}

// Garde une copie texte de chaque élément pour comparer au prochain enregistrement
function prendreInstantane() {
  instantane = {};
  for (const cle of Object.keys(TABLES)) {
    instantane[cle] = new Map(db[cle].map(el => [el.id, JSON.stringify(el)]));
  }
  instantane.reglages = JSON.stringify(db.reglages || {});
}

async function toutLire(table) {
  // Supabase renvoie 1000 lignes max par demande : on lit par pages
  const lignes = [];
  for (let debut = 0; ; debut += 1000) {
    const { data, error } = await sb.from(table).select("data").range(debut, debut + 999);
    if (error) throw error;
    lignes.push(...data.map(l => l.data));
    if (data.length < 1000) break;
  }
  return lignes;
}

const Donnees = {
  // Promesse résolue quand les données sont chargées : chaque page attend ça avant de s'afficher
  pret: null,

  async demarrer() {
    if (!window.CONFIG || !CONFIG.supabaseCle || CONFIG.supabaseCle.startsWith("COLLE_ICI")) {
      throw new Error("La clé Supabase n'est pas encore dans js/config.js.");
    }
    await chargerScript("https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.min.js");
    sb = window.supabase.createClient(CONFIG.supabaseUrl, CONFIG.supabaseCle);
    if (pageConnexion) return;

    if (codeDuLien) {
      // Mode client : une seule fonction sécurisée renvoie ses données (rien des autres clients)
      const { data, error } = await sb.rpc("client_donnees", { p_code: codeDuLien });
      if (error) throw error;
      if (data) Object.assign(db, data);
    } else {
      // Mode coach : il faut être connecté
      const { data: { session } } = await sb.auth.getSession();
      if (!session) {
        location.href = "connexion.html?retour=" + encodeURIComponent(location.pathname.split("/").pop() + location.search);
        return new Promise(() => { }); // la page ne s'affiche pas pendant la redirection
      }
      const listes = await Promise.all(Object.values(TABLES).map(toutLire));
      Object.keys(TABLES).forEach((cle, i) => { db[cle] = listes[i]; });
      const { data: reglages } = await sb.from("reglages").select("data").eq("id", "reglages").maybeSingle();
      db.reglages = reglages?.data || {};
    }
    for (const cle of Object.keys(TABLES)) db[cle] ||= [];
    db.reglages ||= {};
    prendreInstantane();
    if (!codeDuLien) await proposerImportation();
  },

  // Envoie à Supabase ce qui a changé depuis le dernier envoi
  synchroniser() {
    const changements = [];
    for (const [cle, table] of Object.entries(TABLES)) {
      const avant = instantane[cle] || new Map();
      const maintenant = new Map(db[cle].map(el => [el.id, JSON.stringify(el)]));
      for (const [id, texte] of maintenant) {
        if (avant.get(id) !== texte) changements.push({ cle, table, id, type: "maj", data: JSON.parse(texte) });
      }
      for (const id of avant.keys()) {
        if (!maintenant.has(id)) changements.push({ cle, table, id, type: "suppression" });
      }
      instantane[cle] = maintenant;
    }
    const reglages = JSON.stringify(db.reglages || {});
    if (reglages !== instantane.reglages && !codeDuLien) {
      changements.push({ cle: "reglages", table: "reglages", id: "reglages", type: "maj", data: db.reglages });
      instantane.reglages = reglages;
    }
    if (!changements.length) return;

    envoisEnCours++;
    fileEnvoi = fileEnvoi.then(async () => {
      for (const c of changements) {
        try {
          await envoyer(c);
        } catch (e) {
          console.error(e);
          // On oublie l'instantané de cet élément : il sera renvoyé au prochain enregistrement
          if (instantane[c.cle] instanceof Map) instantane[c.cle].delete(c.id);
          if (typeof message === "function") message("Erreur d'enregistrement en ligne : " + (e.message || e));
        }
      }
    }).finally(() => { envoisEnCours--; });
  },

  // Envoie une photo dans Supabase Storage (dossier « photos ») et renvoie son adresse publique.
  // La photo est d'abord réduite à 1200 px de côté max, en JPEG, pour rester légère.
  async televerserPhoto(fichier) {
    if (codeDuLien) throw new Error("Seul le coach peut ajouter des photos.");
    const image = await createImageBitmap(fichier);
    const echelle = Math.min(1, 1200 / Math.max(image.width, image.height));
    const toile = document.createElement("canvas");
    toile.width = Math.round(image.width * echelle);
    toile.height = Math.round(image.height * echelle);
    toile.getContext("2d").drawImage(image, 0, 0, toile.width, toile.height);
    const blob = await new Promise(ok => toile.toBlob(ok, "image/jpeg", 0.85));
    const chemin = `exercices/${this.nouvelId("photo")}.jpg`;
    const { error } = await sb.storage.from("photos").upload(chemin, blob, { contentType: "image/jpeg" });
    if (error) throw error;
    return sb.storage.from("photos").getPublicUrl(chemin).data.publicUrl;
  },

  async deconnecter() {
    await sb.auth.signOut();
    location.href = "connexion.html";
  },

  // Crée un identifiant unique, ex. "c-lq8x2k"
  nouvelId(prefixe) {
    return prefixe + "-" + Date.now().toString(36) + Math.random().toString(36).slice(2, 6);
  },

  // Code secret pour le lien client (long et difficile à deviner)
  nouveauCode() {
    const lettres = "abcdefghijkmnpqrstuvwxyz23456789";
    const hasard = crypto.getRandomValues(new Uint32Array(16));
    return Array.from(hasard, n => lettres[n % lettres.length]).join("");
  },
};

async function envoyer(c) {
  if (codeDuLien) {
    // Le client passe par des fonctions qui vérifient son code
    if (!TABLES_CLIENT.includes(c.cle)) return;
    const { error } = c.type === "maj"
      ? await sb.rpc("client_enregistrer", { p_code: codeDuLien, p_table: c.table, p_id: c.id, p_data: c.data })
      : await sb.rpc("client_supprimer", { p_code: codeDuLien, p_table: c.table, p_id: c.id });
    if (error) throw error;
    return;
  }
  const { error } = c.type === "maj"
    ? await sb.from(c.table).upsert({ id: c.id, data: c.data, updated_at: new Date().toISOString() })
    : await sb.from(c.table).delete().eq("id", c.id);
  if (error) throw error;
}

// Après un enregistrement, les pages appellent cette fonction
function enregistrer() { Donnees.synchroniser(); }

// Avertir si on quitte la page pendant un envoi
window.addEventListener("beforeunload", e => {
  if (envoisEnCours > 0) { e.preventDefault(); e.returnValue = ""; }
});

// Importer une seule fois les données gardées dans ce navigateur (ancienne version de l'app)
async function proposerImportation() {
  let ancien = null;
  try { ancien = JSON.parse(localStorage.getItem("coaching-app-v2") || "null"); } catch { ancien = null; }
  if (!ancien) return;
  const aImporter = ["clients", "programmes", "seances", "recettes", "plansNutrition"]
    .reduce((t, cle) => t + (ancien[cle]?.length || 0), 0);
  const exercicesAjoutes = (ancien.exercices || []).filter(e => !db.exercices.some(x => x.id === e.id));
  if (!aImporter && !exercicesAjoutes.length) { localStorage.removeItem("coaching-app-v2"); return; }
  if (!confirm(`Ce navigateur contient des données de l'ancienne version de l'app (${aImporter} éléments).\nLes envoyer en ligne maintenant ?`)) return;
  for (const cle of ["clients", "programmes", "seances", "recettes", "plansNutrition"]) {
    for (const el of ancien[cle] || []) {
      const i = db[cle].findIndex(x => x.id === el.id);
      if (i >= 0) db[cle][i] = el; else db[cle].push(el);
    }
  }
  db.exercices.push(...exercicesAjoutes);
  if (ancien.reglages) db.reglages = { ...ancien.reglages, ...db.reglages };
  enregistrer();
  await fileEnvoi;
  localStorage.setItem("coaching-app-v2-importe", localStorage.getItem("coaching-app-v2"));
  localStorage.removeItem("coaching-app-v2");
  alert("Importation terminée.");
}

Donnees.pret = Donnees.demarrer().catch(e => {
  console.error(e);
  afficherErreurGlobale("Impossible de charger les données : " + (e.message || e));
  throw e;
});

// ---------- Petites fonctions de recherche ----------
function trouverClient(id) { return db.clients.find(c => c.id === id); }
function trouverExercice(id) { return db.exercices.find(e => e.id === id); }
function programmeDuClient(clientId) { return db.programmes.find(p => p.clientId === clientId); }
function seancesDuClient(clientId) {
  return db.seances.filter(s => s.clientId === clientId).sort((a, b) => b.date.localeCompare(a.date));
}

// Plan nutritionnel du client : celui en cours, sinon le plus récent
function planNutritionDuClient(clientId) {
  const plans = (db.plansNutrition || []).filter(p => p.clientId === clientId)
    .sort((a, b) => (b.debut || "").localeCompare(a.debut || ""));
  const d = new Date();
  const aujourdhuiLocal = new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10); // date d'ici, pas celle de Londres
  return plans.find(p => p.debut <= aujourdhuiLocal) || plans[0];
}
