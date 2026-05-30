using 'app.bicep'

param namePrefix = 'weinongw-faqbot'
param uamiName = 'id-weinongw-faqbot'
param acrName = 'acrweinongwfaqbot'
param containerEnvName = 'cae-weinongw-faqbot'
param aoaiAccountName = 'weinongw-oai'

param chatDeployment = 'gpt-5.4'
param embeddingDeployment = 'text-embedding-3-large'
param aoaiApiVersion = '2024-06-01'

// containerImage MUST be supplied at deploy time via -p containerImage=...
// because the deploy script computes it from ACR login server + tag.
param containerImage = ''
