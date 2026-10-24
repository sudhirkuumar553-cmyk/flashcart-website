const {setGlobalOptions} = require("firebase-functions/v2");

const {

  onDocumentCreated,

  onDocumentUpdated,

} = require("firebase-functions/v2/firestore");

const {logger} = require("firebase-functions");



const {initializeApp} = require("firebase-admin/app");

const {

  getFirestore,

  FieldValue,

} = require("firebase-admin/firestore");

const {getMessaging} = require("firebase-admin/messaging");



initializeApp();



const db = getFirestore();

const messaging = getMessaging();



// ============================================================

// GLOBAL SETTINGS

// ============================================================



setGlobalOptions({

  maxInstances: 10,

});



// ============================================================

// HELPERS

// ============================================================



function toMillis(value) {

  if (!value) return Number.MAX_SAFE_INTEGER;



  if (typeof value.toMillis === "function") {

    return value.toMillis();

  }



  if (value instanceof Date) {

    return value.getTime();

  }



  if (typeof value === "number") {

    return value;

  }



  if (typeof value === "string") {

    const parsed = Date.parse(value);

    return Number.isNaN(parsed) ?

      Number.MAX_SAFE_INTEGER :

      parsed;

  }



  return Number.MAX_SAFE_INTEGER;

}



// ------------------------------------------------------------

// Check whether an order still needs a delivery partner

// ------------------------------------------------------------



function isUnassignedOrder(data) {

  const partnerId =

    data.deliveryPartnerId ||

    data.deliveryBoyId ||

    data.assignedPartnerId ||

    "";



  const assignmentStatus =

    String(data.assignmentStatus || "").toLowerCase();



  if (partnerId.toString().trim() !== "") {

    return false;

  }



  if (assignmentStatus === "assigned") {

    return false;

  }



  if (assignmentStatus === "cancelled") {

    return false;

  }



  if (assignmentStatus === "canceled") {

    return false;

  }



  if (assignmentStatus === "completed") {

    return false;

  }



  return true;

}



// ------------------------------------------------------------

// Check whether order is eligible for delivery assignment

// ------------------------------------------------------------



function isAssignableOrder(data) {

  if (!isUnassignedOrder(data)) {

    return false;

  }



  const status = String(data.status || "")

      .trim()

      .toLowerCase();



  const blockedStatuses = [

    "cancelled",

    "canceled",

    "delivered",

    "completed",

    "rejected",

    "refunded",

  ];



  if (blockedStatuses.includes(status)) {

    return false;

  }



  return true;

}



// ------------------------------------------------------------

// FIFO time for delivery partners

// ------------------------------------------------------------



function partnerQueueTime(data) {

  return Math.min(

      toMillis(data.onlineSince),

      toMillis(data.lastOnlineAt),

      toMillis(data.createdAt),

  );

}



// ------------------------------------------------------------

// Delivery partner eligibility

// ------------------------------------------------------------



function isEligiblePartner(data) {

  if (data.active !== true) {

    return false;

  }



  if (data.online !== true) {

    return false;

  }



  if (data.availableForOrder !== true) {

    return false;

  }



  const activeOrderId =

    data.activeOrderId ? data.activeOrderId.toString().trim() : "";



  if (activeOrderId !== "") {

    return false;

  }



  return true;

}



// ------------------------------------------------------------

// Order queue time

// ------------------------------------------------------------



function orderQueueTime(data) {

  return Math.min(

      toMillis(data.createdAt),

      toMillis(data.orderCreatedAt),

      toMillis(data.updatedAt),

  );

}



// ============================================================

// GET NEXT FIFO ORDER

// ============================================================



async function getOldestPendingOrder() {

  const snapshot = await db

      .collection("orders")

      .get();



  const candidates = snapshot.docs

      .filter((doc) => isAssignableOrder(doc.data()))

      .sort((a, b) => {

        return orderQueueTime(a.data()) -

            orderQueueTime(b.data());

      });



  if (candidates.length === 0) {

    return null;

  }



  return candidates[0];

}



// ============================================================

// GET FIFO PARTNERS

// ============================================================



async function getEligiblePartners() {

  const snapshot = await db

      .collection("deliveryPartners")

      .get();



  const partners = snapshot.docs

      .filter((doc) => isEligiblePartner(doc.data()))

      .sort((a, b) => {

        return partnerQueueTime(a.data()) -

            partnerQueueTime(b.data());

      });



  return partners;

}



// ============================================================

// SEND FCM NEW ORDER NOTIFICATION

// ============================================================



async function sendNewOrderNotification({

  partnerId,

  partnerData,

  orderId,

  orderData,

}) {

  const token =

     partnerData.fcmToken ? partnerData.fcmToken.toString().trim() : "";



  if (!token) {

    logger.warn(

        `No FCM token found for partner ${partnerId}`,

    );

    return;

  }



  const customerName =

    orderData.customerName ?

        orderData.customerName.toString() :

        "Customer";



  const amount =

    orderData.totalAmount ?

        orderData.totalAmount :

        orderData.total ?

            orderData.total :

            orderData.amount ?

                orderData.amount :

                "";



  const orderShort =

      orderId.length > 8 ?

        orderId.substring(0, 8).toUpperCase() :

        orderId.toUpperCase();



  const body = amount !== "" ?

    `Order #${orderShort} assigned • ₹${amount}` :

    `Order #${orderShort} has been assigned to you`;



  try {

    const response = await messaging.send({

      token: token,



      notification: {

        title: "🚚 New Delivery Order",

        body: body,

      },



      data: {

        type: "new_order",

        orderId: orderId,

        partnerId: partnerId,

        customerName: customerName,

      },



      android: {

        priority: "high",

        notification: {

          channelId: "flashcart_orders",

          sound: "default",

          priority: "high",

        },

      },

    });



    logger.info(

        `FCM sent successfully for order ${orderId}`,

        {

          partnerId,

          messageId: response,

        },

    );

  } catch (error) {

    logger.error(

        `FCM failed for order ${orderId}`,

        {

          partnerId,

          error: error.message,

        },

    );

  }

}



// ============================================================

// ASSIGN ONE ORDER TO FIFO PARTNER

// ============================================================



async function assignOrderToPartner(orderDoc) {

  if (!orderDoc || !orderDoc.exists) {

    return false;

  }



  const orderId = orderDoc.id;

  const orderRef = db.collection("orders").doc(orderId);



  const partners = await getEligiblePartners();



  if (partners.length === 0) {

    logger.info(

        `No eligible delivery partner for order ${orderId}`,

    );

    return false;

  }



  for (const partnerDoc of partners) {

    const partnerRef =

        db.collection("deliveryPartners").doc(partnerDoc.id);



    try {

      const result = await db.runTransaction(

          async (transaction) => {

            // IMPORTANT:

            // All transaction reads happen before writes.



            const freshOrder =

                await transaction.get(orderRef);



            const freshPartner =

                await transaction.get(partnerRef);



            if (!freshOrder.exists) {

              return {

                assigned: false,

                reason: "order_missing",

              };

            }



            if (!freshPartner.exists) {

              return {

                assigned: false,

                reason: "partner_missing",

              };

            }



            const freshOrderData =

                freshOrder.data() || {};



            const freshPartnerData =

                freshPartner.data() || {};



            // Another process already assigned this order.

            if (!isAssignableOrder(freshOrderData)) {

              return {

                assigned: false,

                alreadyAssigned: true,

              };

            }



            // Partner may have gone offline or become busy

            // between queue read and transaction.

            if (!isEligiblePartner(freshPartnerData)) {

              return {

                assigned: false,

                retryNextPartner: true,

              };

            }



            const partnerName =

    freshPartnerData.name ?

        freshPartnerData.name.toString() :

        freshPartnerData.fullName ?

            freshPartnerData.fullName.toString() :

            "Delivery Partner";



            const partnerPhone =

                freshPartnerData.phone ||

                freshPartnerData.mobile ||

                freshPartnerData.mobileNumber ||

                "";



            transaction.update(orderRef, {

              deliveryPartnerId: partnerDoc.id,

              deliveryPartnerName: partnerName,

              deliveryPartnerPhone: partnerPhone,



              assignmentStatus: "assigned",



              assignedAt:

                  FieldValue.serverTimestamp(),



              updatedAt:

                  FieldValue.serverTimestamp(),

            });



            transaction.set(

                partnerRef,

                {

                  availableForOrder: false,



                  activeOrderId: orderId,



                  lastAssignedAt:

                      FieldValue.serverTimestamp(),



                  assignmentStatus: "assigned",



                  updatedAt:

                      FieldValue.serverTimestamp(),

                },

                {merge: true},

            );



            return {

              assigned: true,



              partnerId: partnerDoc.id,



              partnerData: freshPartnerData,



              orderData: freshOrderData,

            };

          },

      );



      if (result.alreadyAssigned) {

        return true;

      }



      if (!result.assigned) {

        continue;

      }



      logger.info(

          `Order ${orderId} assigned to ${result.partnerId}`,

      );



      // Send notification AFTER successful transaction.

      await sendNewOrderNotification({

        partnerId: result.partnerId,

        partnerData: result.partnerData,

        orderId: orderId,

        orderData: result.orderData,

      });



      return true;

    } catch (error) {

      logger.error(

          `Assignment transaction failed for order ${orderId}`,

          {

            partnerId: partnerDoc.id,

            error: error.message,

          },

      );



      // Try next FIFO partner.

      continue;

    }

  }



  return false;

}



// ============================================================

// ASSIGN OLDEST WAITING ORDER

// ============================================================



async function assignOldestWaitingOrder() {

  const orderDoc = await getOldestPendingOrder();



  if (!orderDoc) {

    logger.info("No waiting orders found.");

    return false;

  }



  return assignOrderToPartner(orderDoc);

}



// ============================================================

// 1. NEW ORDER CREATED

// ============================================================



exports.assignNewOrder = onDocumentCreated(

    "orders/{orderId}",

    async (event) => {

      const snapshot = event.data;



      if (!snapshot) {

        logger.warn("New order event has no data.");

        return null;

      }



      const orderData = snapshot.data() || {};

      const orderId = snapshot.id;



      logger.info(

          `New order received: ${orderId}`,

      );



      if (!isAssignableOrder(orderData)) {

        logger.info(

            `Order ${orderId} does not need assignment.`,

        );



        return null;

      }



      await assignOrderToPartner(snapshot);



      return null;

    },

);



// ============================================================

// 2. DELIVERY PARTNER STATUS CHANGED

//

// This catches:

// - partner comes online

// - partner becomes available after delivery

// - partner becomes available again

// ============================================================



exports.assignWaitingOrderWhenPartnerAvailable =

    onDocumentUpdated(

        "deliveryPartners/{partnerId}",

        async (event) => {

          const before = event.data.before.data() || {};

          const after = event.data.after.data() || {};



          const wasEligible =

              isEligiblePartner(before);



          const isNowEligible =

              isEligiblePartner(after);



          // Only act when partner becomes eligible.

          if (!isNowEligible || wasEligible) {

            return null;

          }



          const partnerId =

              event.params.partnerId;



          logger.info(

              `Partner ${partnerId} became available.`,

          );



          await assignOldestWaitingOrder();



          return null;

        },

    );



// ============================================================

// 3. OPTIONAL MANUAL HTTP TEST ENDPOINT

//

// Useful for testing from browser/Postman later.

// It assigns the oldest waiting order.

// ============================================================



const {onRequest} =

    require("firebase-functions/v2/https");



exports.manualAssignWaitingOrder = onRequest(

    async (req, res) => {

      try {

        const assigned =

            await assignOldestWaitingOrder();



        res.status(200).json({

          success: true,

          assigned: assigned,

        });

      } catch (error) {

        logger.error(

            "Manual assignment failed",

            error,

        );



        res.status(500).json({

          success: false,

          error: error.message,

        });

      }

    },

);


// ============================================================
// CEO-ONLY MANAGER / FRANCHISE CREATION
// ============================================================
const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {getAuth} = require("firebase-admin/auth");

async function requireCeo(request) {
  if (!request.auth || !request.auth.uid) {
    throw new HttpsError("unauthenticated", "CEO login required.");
  }
  const snap = await db.collection("ceoAccess").doc(request.auth.uid).get();
  const access = snap.data() || {};
  if (!snap.exists || access.active !== true || !["ceo", "founder"].includes(access.role)) {
    throw new HttpsError("permission-denied", "Only an active CEO/founder can create managers.");
  }
  return request.auth.uid;
}

function cleanText(value, max = 160) {
  return typeof value === "string" ? value.trim().slice(0, max) : "";
}

exports.createManagerAndBranch = onCall({maxInstances: 5, enforceAppCheck: false}, async (request) => {
  const ceoUid = await requireCeo(request);
  const d = request.data || {};
  const name = cleanText(d.name);
  const email = cleanText(d.email, 254).toLowerCase();
  const phone = cleanText(d.phone, 20);
  const aadhaarLast4 = cleanText(d.aadhaarLast4, 4);
  const pan = cleanText(d.pan, 10).toUpperCase();
  const fatherName = cleanText(d.fatherName);
  const fatherAadhaarLast4 = cleanText(d.fatherAadhaarLast4, 4);
  const residentialAddress = cleanText(d.residentialAddress, 500);
  const branchName = cleanText(d.branchName || `${name} Branch`);
  const latitude = Number(d.latitude);
  const longitude = Number(d.longitude);
  const serviceRadiusKm = Number(d.serviceRadiusKm);

  if (!name || !email || !phone || !branchName || !residentialAddress) {
    throw new HttpsError("invalid-argument", "Name, email, phone, branch name and residential address are required.");
  }
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    throw new HttpsError("invalid-argument", "Valid manager email required.");
  }
  if (!Number.isFinite(latitude) || latitude < -90 || latitude > 90 ||
      !Number.isFinite(longitude) || longitude < -180 || longitude > 180) {
    throw new HttpsError("invalid-argument", "Valid branch latitude and longitude required.");
  }
  if (!Number.isFinite(serviceRadiusKm) || serviceRadiusKm < 1 || serviceRadiusKm > 4) {
    throw new HttpsError("invalid-argument", "Service radius must be between 1 and 4 km.");
  }
  if (aadhaarLast4 && !/^\d{4}$/.test(aadhaarLast4)) {
    throw new HttpsError("invalid-argument", "If provided, Aadhaar must be represented by its last 4 digits only.");
  }
  if (fatherAadhaarLast4 && !/^\d{4}$/.test(fatherAadhaarLast4)) {
    throw new HttpsError("invalid-argument", "If provided, father's Aadhaar must be represented by its last 4 digits only.");
  }
  if (pan && !/^[A-Z]{5}[0-9]{4}[A-Z]$/.test(pan)) {
    throw new HttpsError("invalid-argument", "PAN format is invalid.");
  }

  let userRecord;
  try {
    userRecord = await getAuth().createUser({email, displayName: name, emailVerified: false, disabled: false});
  } catch (error) {
    if (error.code === "auth/email-already-exists") {
      throw new HttpsError("already-exists", "This email already has a Firebase Auth account.");
    }
    logger.error("Manager Auth creation failed", {error: error.message});
    throw new HttpsError("internal", "Manager account could not be created.");
  }

  const managerUid = userRecord.uid;
  const counterRef = db.collection("systemCounters").doc("managerId");
  const managerRef = db.collection("managers").doc(managerUid);
  const branchRef = db.collection("branches").doc();
  let managerId = "";
  let resetLink = "";
  try {
    // Prepare the account before committing manager/branch documents.
    // The CEO can securely pass this reset link to the manager.
    await getAuth().setCustomUserClaims(managerUid, {role: "manager"});
    resetLink = await getAuth().generatePasswordResetLink(email);
    await db.runTransaction(async (tx) => {
      const counterSnap = await tx.get(counterRef);
      const next = Number(counterSnap.data()?.value || 0) + 1;
      managerId = `FCM-${String(next).padStart(6, "0")}`;
      tx.set(counterRef, {value: next, updatedAt: FieldValue.serverTimestamp()}, {merge: true});
      const managerData = {
        managerId, uid: managerUid, name, email, phone,
        aadhaarLast4: aadhaarLast4 || null,
        pan: pan || null,
        fatherName: fatherName || null,
        fatherAadhaarLast4: fatherAadhaarLast4 || null,
        residentialAddress,
        branchId: branchRef.id, branchName,
        role: "manager", active: true, documents: {},
        createdBy: ceoUid, createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      };
      tx.set(managerRef, managerData);
      tx.set(branchRef, {
        branchId: branchRef.id, branchName, name: branchName,
        managerId, managerUid, managerName: name, managerEmail: email,
        managerPhone: phone, latitude, longitude,
        branchLatitude: latitude, branchLongitude: longitude,
        serviceRadiusKm: Math.min(4, serviceRadiusKm),
        locationSet: true, active: true,
        createdBy: ceoUid, createdAt: FieldValue.serverTimestamp(),
        locationUpdatedAt: FieldValue.serverTimestamp(),
      });
    });
    await getAuth().setCustomUserClaims(managerUid, {role: "manager", managerId, branchId: branchRef.id});
    return {success: true, managerUid, managerId, branchId: branchRef.id, resetLink};
  } catch (error) {
    // Do not leave an unusable Auth account if the database setup failed.
    try { await getAuth().deleteUser(managerUid); } catch (_) {}
    if (error instanceof HttpsError) throw error;
    logger.error("Manager/branch database creation failed", {error: error.message});
    throw new HttpsError("internal", "Manager record could not be completed. Try again.");
  }
});

exports.updateManagerDocuments = onCall({maxInstances: 5, enforceAppCheck: false}, async (request) => {
  const ceoUid = await requireCeo(request);
  const d = request.data || {};
  const managerUid = cleanText(d.managerUid, 128);
  const docs = d.documents;
  if (!managerUid || !docs || typeof docs !== "object" || Array.isArray(docs)) {
    throw new HttpsError("invalid-argument", "Manager UID and document paths are required.");
  }
  const allowed = ["aadhaar", "pan", "fatherAadhaar", "residentialCertificate"];
  const safeDocs = {};
  for (const key of allowed) {
    if (docs[key] != null) {
      const path = cleanText(docs[key], 500);
      if (!path.startsWith(`managerDocuments/${managerUid}/`) || path.includes("..")) {
        throw new HttpsError("invalid-argument", "Invalid private document path.");
      }
      safeDocs[key] = path;
    }
  }
  const managerRef = db.collection("managers").doc(managerUid);
  const snap = await managerRef.get();
  if (!snap.exists) throw new HttpsError("not-found", "Manager record not found.");
  await managerRef.set({documents: safeDocs, documentsUpdatedAt: FieldValue.serverTimestamp(), documentsUpdatedBy: ceoUid}, {merge: true});
  return {success: true};
});
