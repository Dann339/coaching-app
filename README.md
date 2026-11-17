# CoachPlan — ton app de coaching

Version de départ, en HTML / CSS / JavaScript simple (aucune installation).
Elle part de zéro : seulement la bibliothèque de 263 exercices. Aucun client, programme, séance ni recette.
Un nouveau programme a la même structure que ton Excel : 4 entraînements (à renommer), avec Séries, Reps et Consignes.

## Ouvrir l'app

1. Dans VS Code : **Fichier > Ouvrir le dossier…** et choisis `Documents\coaching-app`.
2. Installe l'extension **Live Server** (icône Extensions à gauche, cherche « Live Server »).
3. Clic droit sur `index.html` > **Open with Live Server**. L'app s'ouvre dans ton navigateur.
4. Chaque fois que tu enregistres un fichier, la page se recharge toute seule.

## Les pages

| Fichier | Page |
| --- | --- |
| `index.html` | Clients : liste, ajout, lien client |
| `exercices.html` | Bibliothèque d'exercices, avec photo et vidéo |
| `programme.html` | Programme d'un client : entraînements, exercices, séries, reps, consignes |
| `seance.html` | Noter une séance (poids et reps par série, cardio) |
| `progression.html` | Poids max et volume par semaine, records |
| `nutrition.html` | Plans nutritionnels : objectifs de macros par client, recettes suggérées |
| `recettes.html` | Recettes avec vidéo (sous-section de Nutrition) |
| `client.html` | Ce que le client voit (lecture seule) |
| `plan-pdf.html` | Version PDF du plan (entraînements, nutrition, recettes) |

## Les autres fichiers

| Fichier | Rôle |
| --- | --- |
| `css/style.css` | Couleurs, polices, mise en page (les couleurs sont en haut) |
| `js/commun.js` | Outils partagés : menu, vidéos, calcul du volume |
| `js/stockage.js` | Où les données sont gardées |
| `js/donnees-depart.js` | La bibliothèque d'exercices de départ (déjà copiée dans supabase.sql) |
| `js/config.js` | Connexion à Supabase |

## Données en ligne (Supabase)

Les données sont gardées en ligne dans Supabase (projet `gjklwefaldmhbgmpqkgk`).

- `js/config.js` : adresse du projet et clé publishable (jamais la clé secrète).
- `supabase.sql` : à coller une fois dans Supabase > SQL Editor (tables, sécurité, exercices de départ).
- `connexion.html` : connexion du coach (compte créé dans Supabase > Authentication > Users).
- Le client n'a pas de compte : son lien (`client.html?code=…`) lui donne accès à SES données seulement.
- `js/stockage.js` envoie à Supabase seulement ce qui change (un client, une séance, un plan…).

## Ajouter une vidéo

Ouvre un exercice (page Exercices) ou une recette, colle un lien YouTube ou Vimeo dans « Vidéo ».
Pour tes propres vidéos : publie-les sur YouTube en mode **Non répertoriée**.
