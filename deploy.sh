#!/bin/bash
# Deploy script — Validation Posts SAMEDIA 2026
# Netlify site ID : 81f2273d-532f-4801-b767-44164e6e756b

SITE_ID="81f2273d-532f-4801-b767-44164e6e756b"
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "🚀 Déploiement Validation Posts SAMEDIA..."
echo "   Dossier : $DIR"
echo "   Site ID : $SITE_ID"
echo ""

netlify deploy \
  --dir "$DIR" \
  --site "$SITE_ID" \
  --prod \
  --message "Update Validation Posts SAMEDIA $(date '+%Y-%m-%d %H:%M')"

if [ $? -eq 0 ]; then
  echo ""
  echo "✅ Déploiement réussi !"
  echo "   URL : https://samedia-posts-validation.netlify.app"
else
  echo ""
  echo "❌ Déploiement échoué."
  echo "   → Vérifier les crédits Netlify sur app.netlify.com"
  echo "   → Ou déposer le dossier manuellement sur app.netlify.com/drop"
fi
