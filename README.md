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

## Les autres fichiers

| Fichier | Rôle |
| --- | --- |
| `css/style.css` | Couleurs, polices, mise en page (les couleurs sont en haut) |
| `js/commun.js` | Outils partagés : menu, vidéos, calcul du volume |
| `js/stockage.js` | Où les données sont gardées |
| `js/donnees-depart.js` | La bibliothèque d'exercices de départ |

## Important : données dans le navigateur

Pour l'instant, les données sont gardées **dans ton navigateur seulement**.
Si tu vides l'historique du navigateur, tes ajouts disparaissent.
Le lien client ne fonctionne que sur ton ordinateur.

**Prochaine étape (semaine 1 du plan) :** brancher Supabase pour garder les données en ligne.
Demande à Claude dans VS Code :

> Remplace js/stockage.js pour utiliser Supabase au lieu de localStorage, en gardant les mêmes
> fonctions pour que les pages continuent de marcher. Ajoute une page de connexion pour que
> seulement moi puisse modifier les données. Explique-moi chaque étape à faire dans Supabase.

## Ajouter une vidéo

Ouvre un exercice (page Exercices) ou une recette, colle un lien YouTube ou Vimeo dans « Vidéo ».
Pour tes propres vidéos : publie-les sur YouTube en mode **Non répertoriée**.
