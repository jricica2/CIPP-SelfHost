const { TableClient, TableServiceClient } = require("@azure/data-tables");

// Azurite connection string (matches docker-compose environment)
const AZURITE_CONN =
  process.env.AZURITE_CONNECTION_STRING ||
  "DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;" +
    "AccountKey=Eby8vdM02xNoBnZf6KgBVU4=;" +
    "BlobEndpoint=http://azurite:10000/devstoreaccount1;" +
    "QueueEndpoint=http://azurite:10001/devstoreaccount1;" +
    "TableEndpoint=http://azurite:10002/devstoreaccount1;";

const SAM_APPLICATION_ID = process.env.SAM_APPLICATION_ID;
const SAM_APPLICATION_SECRET = process.env.SAM_APPLICATION_SECRET;
const SAM_TENANT_ID = process.env.SAM_TENANT_ID;
const SAM_REFRESH_TOKEN = process.env.SAM_REFRESH_TOKEN;

async function waitForAzurite(maxRetries = 30, delayMs = 2000) {
  const serviceClient = TableServiceClient.fromConnectionString(AZURITE_CONN);
  for (let i = 0; i < maxRetries; i++) {
    try {
      // Try to list tables - if Azurite is up, this succeeds
      const iter = serviceClient.listTables();
      await iter.next();
      console.log("Azurite is ready.");
      return;
    } catch {
      console.log(
        "Waiting for Azurite... (" + (i + 1) + "/" + maxRetries + ")"
      );
      await new Promise((r) => setTimeout(r, delayMs));
    }
  }
  throw new Error("Azurite did not become ready in time.");
}

async function seedDevSecrets() {
  const client = TableClient.fromConnectionString(AZURITE_CONN, "DevSecrets");

  // Create the table if it doesn't exist
  try {
    await client.createTable();
    console.log("Created DevSecrets table.");
  } catch (err) {
    if (err.statusCode === 409) {
      console.log("DevSecrets table already exists.");
    } else {
      throw err;
    }
  }

  // Check if credentials are already seeded
  try {
    const existing = await client.getEntity("Secret", "Secret");
    if (existing && existing.ApplicationID) {
      console.log(
        "DevSecrets already populated (ApplicationID: " +
          existing.ApplicationID +
          "). Skipping seed."
      );
      return;
    }
  } catch (err) {
    // Entity doesn't exist yet - proceed with seeding
    if (err.statusCode !== 404) {
      throw err;
    }
  }

  // Validate required env vars
  if (
    !SAM_APPLICATION_ID ||
    !SAM_APPLICATION_SECRET ||
    !SAM_TENANT_ID ||
    !SAM_REFRESH_TOKEN
  ) {
    console.error(
      "ERROR: Missing required SAM credentials in environment variables."
    );
    console.error("Required: SAM_APPLICATION_ID, SAM_APPLICATION_SECRET,");
    console.error("          SAM_TENANT_ID, SAM_REFRESH_TOKEN");
    console.error("Please check your .env file.");
    process.exit(1);
  }

  // Seed the entity
  const entity = {
    partitionKey: "Secret",
    rowKey: "Secret",
    ApplicationID: SAM_APPLICATION_ID,
    ApplicationSecret: SAM_APPLICATION_SECRET,
    TenantID: SAM_TENANT_ID,
    RefreshToken: SAM_REFRESH_TOKEN,
  };

  await client.upsertEntity(entity, "Replace");
  console.log("DevSecrets seeded successfully.");
  console.log("  ApplicationID: " + SAM_APPLICATION_ID);
  console.log("  TenantID: " + SAM_TENANT_ID);
}

async function main() {
  console.log("=== CIPP Self-Host Setup ===");

  await waitForAzurite();
  await seedDevSecrets();

  console.log("=== Setup complete ===");
}

main().catch((err) => {
  console.error("Setup failed:", err.message);
  process.exit(1);
});
