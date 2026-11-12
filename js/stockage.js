// ============================================================
// STOCKAGE DES DONNÉES
// Pour l'instant, tout est gardé dans ce navigateur (localStorage).
// Semaine 1 du plan : on remplacera ce fichier par Supabase,
// sans toucher aux pages, car elles passent toutes par "Donnees".
// ============================================================

const CLE_STOCKAGE = "coaching-app-v2"; // nouveau nom : les anciennes données démo sont ignorées

const Donnees = {
  // Lit toutes les données (ou les données de départ au premier lancement)
  charger() {
    try {
      const texte = localStorage.getItem(CLE_STOCKAGE);
      if (texte) {
        const donnees = JSON.parse(texte);
        donnees.plansNutrition ||= []; // ajouté plus tard : on complète les anciennes données
        return donnees;
      }
    } catch (e) {
      console.warn("Lecture impossible, on repart de zéro.", e);
    }
    const copie = JSON.parse(JSON.stringify(window.DONNEES_DEPART));
    copie.plansNutrition ||= [];
    this.sauver(copie);
    return copie;
  },

  sauver(db) {
    try {
      localStorage.setItem(CLE_STOCKAGE, JSON.stringify(db));
    } catch (e) {
      alert("Impossible d'enregistrer dans ce navigateur : " + e.message);
    }
  },

  // Efface tout et repart de zéro (garde la bibliothèque d'exercices)
  reinitialiser() {
    localStorage.removeItem(CLE_STOCKAGE);
    return this.charger();
  },

  // Crée un identifiant unique, ex. "c-lq8x2k"
  nouvelId(prefixe) {
    return prefixe + "-" + Date.now().toString(36) + Math.random().toString(36).slice(2, 6);
  },

  // Code secret pour le lien client (long et difficile à deviner)
  nouveauCode() {
    const lettres = "abcdefghijkmnpqrstuvwxyz23456789";
    let code = "";
    for (let i = 0; i < 12; i++) code += lettres[Math.floor(Math.random() * lettres.length)];
    return code;
  },
};

// "db" = toutes les données, utilisées par chaque page
let db = Donnees.charger();
function enregistrer() { Donnees.sauver(db); }

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
  return plans.find(p => p.debut <= new Date().toISOString().slice(0, 10)) || plans[0];
}
