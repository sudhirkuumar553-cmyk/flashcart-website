'use strict';







const { onRequest } = require('firebase-functions/v2/https');



const {

  defineSecret,

  defineString

} = require('firebase-functions/params');



const logger = require('firebase-functions/logger');



const admin = require('firebase-admin');



const crypto = require('node:crypto');







if (!admin.apps.length) admin.initializeApp();



const db = admin.firestore();



const RAZORPAY_KEY_ID = defineSecret('RAZORPAY_KEY_ID');



const RAZORPAY_KEY_SECRET = defineSecret('RAZORPAY_KEY_SECRET');



const RAZORPAY_WEBHOOK_SECRET = defineSecret('RAZORPAY_WEBHOOK_SECRET');



const REGION = 'asia-south1';



const rupees = n => Math.round(Number(n) * 100) / 100;



const paise = n => Math.round(rupees(n) * 100);



const fail = (message, status = 400) => Object.assign(new Error(message), { status });



const safeId = s => /^[A-Za-z0-9\_-]{8,80}$/.test(String(s || ''));







function cors(req, res) {



  res.set('Access-Control-Allow-Origin', '*');



  res.set('Access-Control-Allow-Methods', 'POST, OPTIONS');



  res.set('Access-Control-Allow-Headers', 'Content-Type, Authorization, X-Razorpay-Signature');



  res.set('Cache-Control', 'no-store');



  if (req.method === 'OPTIONS') { res.status(204).send(''); return true; }



  return false;



}



async function requireUid(req) {



  const h = String(req.headers.authorization || '');



  if (!h.startsWith('Bearer ')) throw fail('Login session नहीं मिला।', 401);



  try { return (await admin.auth().verifyIdToken(h.slice(7), true)).uid; }



  catch { throw fail('Firebase login token invalid/expired है।', 401); }



}


function razorHeaders(secret) {
  const id = String(RAZORPAY_KEY_ID.value() || '').trim();
  const cleanSecret = String(secret || '').trim();
  if (!id || !cleanSecret) throw fail('Razorpay secrets configure नहीं हैं।', 500);
  return { id, secretLen: cleanSecret.length, authorization: 'Basic ' + Buffer.from(`${id}:${cleanSecret}`).toString('base64') };
}





async function razorpay(path, method, body, secret) {



  const cfg = razorHeaders(secret);



  const r = await fetch(`https://api.razorpay.com/v1/${path}`, {



    method, headers: { Authorization: cfg.authorization, 'Content-Type': 'application/json' },



    body: body ? JSON.stringify(body) : undefined



  });



  const d = await r.json().catch(() => ({}));



    if (!r.ok) { logger.error('Razorpay API failed', { path, status: r.status, d }); throw fail(`Razorpay Error (${r.status}) [ID:${cfg.id.slice(0, 12)}.. Len:${cfg.secretLen}]: ${d.error?.description || d.error?.code || 'response नहीं मिला'}`, 502); }






  return d;



}



function distanceKm(aLat, aLng, bLat, bLng) {



  const rad = x => x * Math.PI / 180;



  const dLat = rad(bLat-aLat), dLng = rad(bLng-aLng);



  const a = Math.sin(dLat/2)**2 + Math.cos(rad(aLat))*Math.cos(rad(bLat))*Math.sin(dLng/2)**2;



  return 6371 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a));



}



async function getActiveBranch(lat, lng) {



  const snap = await db.collection('branches').where('active', '==', true).get();



  let best = null;



  for (const doc of snap.docs) {



    const b = doc.data();



    const bLat = Number(b.latitude ?? b.branchLatitude), bLng = Number(b.longitude ?? b.branchLongitude);



    if (!Number.isFinite(bLat) || !Number.isFinite(bLng) || b.locationSet === false) continue;



    const radius = Math.min(4, Math.max(0, Number(b.serviceRadiusKm ?? 4)));



    const distance = distanceKm(lat, lng, bLat, bLng);



    if (radius > 0 && distance <= radius && (!best || distance < best.distance)) {



      best = { id: doc.id, name: String(b.branchName || b.name || 'FlashCart Branch'), lat: bLat, lng: bLng, radius, distance };



    }



  }



  if (!best) throw fail('Unserviceable area: आपके पते से 4 KM के अंदर active branch नहीं है।', 422);



  return best;



}



async function calculateOrder(uid, orderData) {



  if (!orderData || !Array.isArray(orderData.items) || !orderData.items.length || orderData.items.length > 60) throw fail('Cart items सही नहीं हैं।');



  const lat = Number(orderData.deliveryLatitude), lng = Number(orderData.deliveryLongitude);



  if (!Number.isFinite(lat) || !Number.isFinite(lng) || Math.abs(lat)>90 || Math.abs(lng)>180) throw fail('Delivery location सही नहीं है।');



  const branch = await getActiveBranch(lat, lng);



  const availability = (await db.collection('appConfig').doc('businessAvailability').get()).data() || {};



  if (availability.acceptingOrders === false) throw fail(String(availability.message || 'अभी नए orders बंद हैं।'), 409);



  if (availability.scheduleEnabled === true) {



    const parse = v => { const m = /^(\d{1,2}):(\d{2})$/.exec(String(v||'')); return m && +m[1]<24 && +m[2]<60 ? +m[1]*60 + +m[2] : null; };



    const start=parse(availability.openTime), end=parse(availability.closeTime);



    if (start===null || end===null || start===end) throw fail('Store opening hours configuration सही नहीं है।',409);



    const parts = new Intl.DateTimeFormat('en-GB',{timeZone:'Asia/Kolkata',hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).format(new Date()).split(':');



    const now=+parts[0]*60 + +parts[1], open=start<end ? now>=start&&now<end : now>=start||now<end;



    if (!open) throw fail(String(availability.message || 'अभी नए orders बंद हैं।'),409);



  }



  const items=[]; let itemsTotal=0;



  for (const raw of orderData.items) {



    const productId=String(raw.productId||''), qty=Number(raw.quantity);



    if (!/^[A-Za-z0-9\_-]{1,150}$/.test(productId) || !Number.isInteger(qty) || qty<1 || qty>99) throw fail('Cart में product/quantity invalid है।');



    const snap=await db.collection('products').doc(productId).get();



    if (!snap.exists) throw fail('Cart का एक product अब उपलब्ध नहीं है।',409);



    const p=snap.data();



    const original=Number(p.originalPrice ?? p.price ?? 0);



    const discount=Number(p.discountPercent ?? p.discount ?? 0);



    const selling=Number(p.sellingPrice ?? (discount>0 ? original-original*discount/100 : original));



    const stock=Number(p.stock ?? 0);



    if (p.available===false || !Number.isFinite(selling) || selling<0 || stock<qty) throw fail(`${p.name || 'Product'} का stock उपलब्ध नहीं है।`,409);



    const line=rupees(selling*qty); itemsTotal=rupees(itemsTotal+line);



    items.push({productId,name:String(p.name||'Product'),category:String(p.category||'Other'),unit:String(p.unit||'1 unit'),price:rupees(selling),quantity:qty,total:line,emoji:String(p.emoji||'🛍️'),imageUrl:String(p.imageUrl||''),originalPrice:rupees(original),discount:discount});



  }



  let discountAmount=0, discountPercent=0, offerCode='', offerName='';



  const requestedCode=String(orderData.appliedOfferCode||'').trim().toUpperCase();



  if (requestedCode) {



    const offers=await db.collection('offers').where('active','==',true).get();



    const offerDoc=offers.docs.find(d=>String(d.data().code||'').trim().toUpperCase()===requestedCode);



    if (!offerDoc) throw fail('Offer invalid या inactive है।',409);



    const offer=offerDoc.data(), min=Number(offer.minOrder||0), pct=Number(offer.discountPercent||0);



    if (!(pct>0 && pct<=100) || itemsTotal<min) throw fail('Offer की शर्तें पूरी नहीं हुई हैं।',409);



    discountPercent=pct; discountAmount=rupees(Math.min(itemsTotal,itemsTotal*pct/100)); offerCode=requestedCode; offerName=String(offer.name||requestedCode);



  }



   let handlingProcessingFee = 0, packagingFee = 0, platformFee = 0;
  if (itemsTotal < 69) {
    handlingProcessingFee = 4;
    packagingFee = 4;
    platformFee = 3;
  } else if (itemsTotal <= 349) {
    handlingProcessingFee = 6;
    packagingFee = 5;
    platformFee = 4;
  }
  const deliveryFee = 0;
  const totalPrice = rupees(
    Math.max(
      0,
      itemsTotal + handlingProcessingFee + packagingFee + platformFee + deliveryFee - discountAmount
    )
  );




  if (paise(totalPrice)<100) throw fail('Payment amount कम से कम ₹1 होना चाहिए।');



  return { uid, items, itemsTotal, handlingProcessingFee, packagingFee, platformFee, deliveryFee, discountAmount, discountPercent, appliedOfferCode:offerCode, appliedOfferName:offerName, totalPrice, branch, deliveryLatitude:lat, deliveryLongitude:lng, deliveryAddress:String(orderData.deliveryAddress||'').slice(0,1000), customerName:String(orderData.customerName||'FlashCart Customer').slice(0,100), userPhone:String(orderData.userPhone||'').slice(0,20) };



}



async function createNativeSession(req, res, uid) {



  const { orderId, orderData } = req.body || {};



  if (!safeId(orderId)) throw fail('Checkout ID सही नहीं है।');



  const existing=await db.collection('paymentSessions').doc(orderId).get();



  if (existing.exists) {



    const s=existing.data();



    if (s.userId!==uid) throw fail('यह checkout आपके खाते का नहीं है।',403);



    if (s.status==='created' && s.razorpayOrderId) return res.json({ok:true,keyId:RAZORPAY_KEY_ID.value(),razorpayOrderId:s.razorpayOrderId,amount:s.amountPaise,reused:true});



    throw fail('इस checkout की payment session पहले ही इस्तेमाल हो चुकी है।',409);



  }



  const calc=await calculateOrder(uid,orderData);



  const rOrder=await razorpay('orders','POST',{amount:paise(calc.totalPrice),currency:'INR',receipt:orderId,notes:{orderId,userId:uid,branchId:calc.branch.id}},RAZORPAY_KEY_SECRET.value());



  const now=admin.firestore.FieldValue.serverTimestamp();



  await db.collection('paymentSessions').doc(orderId).create({orderId,userId:uid,status:'created',paymentStatus:'pending',razorpayOrderId:rOrder.id,amountPaise:rOrder.amount,currency:'INR',orderData:{orderId,userId:uid,userPhone:calc.userPhone,customerName:calc.customerName,items:calc.items,itemsTotal:calc.itemsTotal,handlingProcessingFee:calc.handlingProcessingFee,packagingFee:calc.packagingFee,deliveryFee:calc.deliveryFee,discountAmount:calc.discountAmount,discountPercent:calc.discountPercent,appliedOfferCode:calc.appliedOfferCode,appliedOfferName:calc.appliedOfferName,totalPrice:calc.totalPrice,paymentMethod:'Razorpay',paymentStatus:'paid',deliveryAddress:calc.deliveryAddress,deliveryLatitude:calc.deliveryLatitude,deliveryLongitude:calc.deliveryLongitude,deliveryGeoPoint:new admin.firestore.GeoPoint(calc.deliveryLatitude,calc.deliveryLongitude),deliveryLocationSet:true,deliveryLocationUpdatedAt:now,branchId:calc.branch.id,branchName:calc.branch.name,branchLatitude:calc.branch.lat,branchLongitude:calc.branch.lng,serviceRadiusKm:calc.branch.radius,deliveryDistanceKm:Number(calc.branch.distance.toFixed(3)),status:'Order Placed',orderDate:now},createdAt:now});



  return res.json({ok:true,keyId:RAZORPAY_KEY_ID.value(),razorpayOrderId:rOrder.id,amount:rOrder.amount});



}



async function finalizePayment(uid, body) {



  const orderId=String(body.orderId||''), orderIdFromRzp=String(body.razorpayOrderId||''), paymentId=String(body.razorpayPaymentId||''), signature=String(body.razorpaySignature||'');



  if (!safeId(orderId) || !orderIdFromRzp.startsWith('order\_') || !paymentId.startsWith('pay\_')) throw fail('Payment verification data invalid है।');



  const sessionRef=db.collection('paymentSessions').doc(orderId), sessionSnap=await sessionRef.get();



  if (!sessionSnap.exists) throw fail('Payment session नहीं मिली।',404);



  const session=sessionSnap.data();



  if (session.userId!==uid) throw fail('यह payment session आपके खाते का नहीं है।',403);



  if (session.razorpayOrderId!==orderIdFromRzp) throw fail('Razorpay Order mismatch है।',409);



  const expected=crypto.createHmac('sha256',String(RAZORPAY_KEY_SECRET.value() || '').trim()).update(`${orderIdFromRzp}|${paymentId}`).digest('hex');



  const a=Buffer.from(expected), b=Buffer.from(signature);



  if (a.length!==b.length || !crypto.timingSafeEqual(a,b)) throw fail('Payment signature सही नहीं है।',401);



  const payment=await razorpay(`payments/${encodeURIComponent(paymentId)}`,'GET',null,RAZORPAY_KEY_SECRET.value());



  if (payment.order_id!==orderIdFromRzp || Number(payment.amount)!==Number(session.amountPaise) || payment.currency!=='INR') throw fail('Payment amount/order verification failed.',409);



  if (payment.status==='authorized') await razorpay(`payments/${encodeURIComponent(paymentId)}/capture`,'POST',{amount:payment.amount,currency:'INR'},RAZORPAY_KEY_SECRET.value());



  const verified=payment.status==='captured' ? payment : await razorpay(`payments/${encodeURIComponent(paymentId)}`,'GET',null,RAZORPAY_KEY_SECRET.value());



  if (verified.status!=='captured') throw fail('Payment capture अभी confirm नहीं हुआ।',409);



  const orderRef=db.collection('orders').doc(orderId), queueRef=db.collection('deliveryQueue').doc(orderId);



  await db.runTransaction(async tx=>{



    const [freshSession, existingOrder]=await Promise.all([tx.get(sessionRef),tx.get(orderRef)]);



    if (!freshSession.exists || freshSession.data().userId!==uid) throw fail('Payment session invalid है।',409);



    if (existingOrder.exists && existingOrder.data().paymentStatus==='paid') return;



    const orderData=freshSession.data().orderData;



    const quantities=new Map(); for (const item of orderData.items) quantities.set(item.productId,(quantities.get(item.productId)||0)+item.quantity);



    const productSnaps=[]; for (const [id,qty] of quantities) { const ref=db.collection('products').doc(id); const snap=await tx.get(ref); if (!snap.exists || snap.data().available===false || Number(snap.data().stock||0)<qty) throw fail('Payment हो गया, लेकिन stock conflict है। Support से संपर्क करें।',409); productSnaps.push({ref,snap,qty}); }



    for (const p of productSnaps) tx.update(p.ref,{stock:admin.firestore.FieldValue.increment(-p.qty)});



    tx.set(orderRef,{...orderData,razorpayOrderId:orderIdFromRzp,razorpayPaymentId:paymentId,paymentStatus:'paid',paymentVerifiedAt:admin.firestore.FieldValue.serverTimestamp()});



    tx.set(queueRef,{orderId,userId:uid,status:'pending',assignedPartnerId:'',paymentMethod:'Razorpay',paymentStatus:'paid',branchId:orderData.branchId,branchName:orderData.branchName,createdAt:admin.firestore.FieldValue.serverTimestamp()});



    tx.update(sessionRef,{status:'paid',paymentStatus:'paid',razorpayPaymentId:paymentId,verifiedAt:admin.firestore.FieldValue.serverTimestamp()});



  });



  return {ok:true,orderId,paymentStatus:'paid',orderCreated:true};



}







async function placeCodOrder(uid, body) {



  const orderId=String(body.orderId||''), orderData=body.orderData||{};



  if (!safeId(orderId)) throw fail('Order ID सही नहीं है।');



  const orderRef=db.collection('orders').doc(orderId);



  const queueRef=db.collection('deliveryQueue').doc(orderId);



  const existing=await orderRef.get();



  if (existing.exists) {



    if (existing.data().userId!==uid) throw fail('यह order आपके खाते का नहीं है।',403);



    return {ok:true,orderId,orderCreated:true,reused:true};



  }



  const calc=await calculateOrder(uid,orderData);



  const now=admin.firestore.FieldValue.serverTimestamp();



  const order={



    orderId,userId:uid,userPhone:calc.userPhone,customerName:calc.customerName,



    items:calc.items,itemsTotal:calc.itemsTotal,



    handlingProcessingFee:calc.handlingProcessingFee,packagingFee:calc.packagingFee,



    deliveryFee:calc.deliveryFee,discountAmount:calc.discountAmount,



    discountPercent:calc.discountPercent,appliedOfferCode:calc.appliedOfferCode,



    appliedOfferName:calc.appliedOfferName,totalPrice:calc.totalPrice,



    paymentMethod:'Cash on Delivery',paymentStatus:'cod',



    deliveryAddress:calc.deliveryAddress,deliveryLatitude:calc.deliveryLatitude,



    deliveryLongitude:calc.deliveryLongitude,



    deliveryGeoPoint:new admin.firestore.GeoPoint(calc.deliveryLatitude,calc.deliveryLongitude),



    deliveryLocationSet:true,deliveryLocationUpdatedAt:now,



    branchId:calc.branch.id,branchName:calc.branch.name,



    branchLatitude:calc.branch.lat,branchLongitude:calc.branch.lng,



    serviceRadiusKm:calc.branch.radius,deliveryDistanceKm:Number(calc.branch.distance.toFixed(3)),



    status:'Order Placed',orderDate:now



  };



  await db.runTransaction(async tx=>{



    const [orderSnap, queueSnap]=await Promise.all([tx.get(orderRef),tx.get(queueRef)]);



    if (orderSnap.exists) {



      if (orderSnap.data().userId!==uid) throw fail('Order ID conflict.',409);



      return;



    }



    if (queueSnap.exists) throw fail('Delivery queue conflict.',409);



    const quantities=new Map();



    for (const item of calc.items) quantities.set(item.productId,(quantities.get(item.productId)||0)+item.quantity);



    const products=[];



    for (const [id,qty] of quantities) {



      const ref=db.collection('products').doc(id), snap=await tx.get(ref);



      if (!snap.exists || snap.data().available===false || Number(snap.data().stock||0)<qty)



        throw fail('Product stock अभी उपलब्ध नहीं है। Cart refresh करके दोबारा प्रयास करें।',409);



      products.push({ref,qty});



    }



    for (const item of products) tx.update(item.ref,{stock:admin.firestore.FieldValue.increment(-item.qty)});



    tx.create(orderRef,order);



    tx.create(queueRef,{



      orderId,userId:uid,status:'pending',assignedPartnerId:'',



      paymentMethod:'Cash on Delivery',paymentStatus:'cod',



      branchId:calc.branch.id,branchName:calc.branch.name,createdAt:now



    });



  });



  return {ok:true,orderId,orderCreated:true};



}



async function cancelAndRefundOrder(uid, body) {
  const orderId = String(body.orderId || '').trim();
  const reason = String(body.reason || 'Cancelled by customer').slice(0, 200);
  if (!safeId(orderId)) throw fail('Order ID सही नहीं है।');

  const orderRef = db.collection('orders').doc(orderId);
  const orderSnap = await orderRef.get();
  if (!orderSnap.exists) throw fail('Order नहीं मिला।', 404);

  const order = orderSnap.data();
  const status = String(order.status || '').toLowerCase();

  const userDoc = await db.collection('users').doc(uid).get();
  const isAdmin = userDoc.exists && (userDoc.data().role === 'admin' || userDoc.data().isAdmin === true);
  if (order.userId !== uid && !isAdmin) {
    throw fail('आपको इस order को cancel करने की अनुमति नहीं है।', 403);
  }

  if (status === 'cancelled') {
    return {
      ok: true,
      alreadyCancelled: true,
      refundStatus: order.refundStatus || 'none',
      refundId: order.refundId || '',
      message: 'यह order पहले ही cancel हो चुका है।'
    };
  }

  const nonCancellable = ['out_for_delivery', 'picked_up', 'delivered'];
  if (!isAdmin && nonCancellable.includes(status)) {
    throw fail('Order निकल चुका है, अब cancel नहीं हो सकता।', 409);
  }

  const isPaid = String(order.paymentStatus || '').toLowerCase() === 'paid';
  const rzpPaymentId = String(order.razorpayPaymentId || '').trim();
  const cfOrderId = String(order.cashfreeOrderId || '').trim();
   const totalPaid = rupees(order.totalPrice || 0);
  const nonRefundableFees = rupees(
    Number(order.handlingProcessingFee || 0) +
    Number(order.packagingFee || 0) +
    Number(order.platformFee || 0)
  );
  const amountRupees = rupees(Math.max(0, totalPaid - nonRefundableFees));

  let refundStatus = 'not_applicable';
  let refundId = '';
  let refundGateway = '';

  if (isPaid && amountRupees >= 1 && order.refundStatus !== 'initiated' && order.refundStatus !== 'processed') {

    if (rzpPaymentId) {
      const rzpRefund = await razorpay(
        `payments/${encodeURIComponent(rzpPaymentId)}/refund`,
        'POST',
        { amount: paise(amountRupees), speed: 'normal', notes: { orderId, reason } },
        RAZORPAY_KEY_SECRET.value()
      );
      refundStatus = 'initiated';
      refundId = String(rzpRefund.id || '');
      refundGateway = 'razorpay';
    } else if (cfOrderId) {
      const cfRefundId = `rfnd_${orderId}_${Date.now()}`.slice(0, 40);
      const cfRefund = await cashfreeApi(
        `/orders/${encodeURIComponent(cfOrderId)}/refunds`,
        'POST',
        { refund_amount: amountRupees, refund_id: cfRefundId, refund_note: reason }
      );
      refundStatus = 'initiated';
      refundId = String(cfRefund.cf_refund_id || cfRefund.refund_id || cfRefundId);
      refundGateway = 'cashfree';
    }
  }

  await db.runTransaction(async tx => {
    const freshSnap = await tx.get(orderRef);
    if (!freshSnap.exists) return;
    const fresh = freshSnap.data();
    if (String(fresh.status || '').toLowerCase() === 'cancelled') return;

    const items = Array.isArray(fresh.items) ? fresh.items : [];
    for (const item of items) {
      if (item.productId && Number(item.quantity) > 0) {
        const pRef = db.collection('products').doc(String(item.productId));
        tx.update(pRef, { stock: admin.firestore.FieldValue.increment(Number(item.quantity)) });
      }
    }

    tx.update(orderRef, {
      status: 'Cancelled',
      cancelledAt: admin.firestore.FieldValue.serverTimestamp(),
      cancelledBy: isAdmin ? 'admin' : 'customer',
      cancelReason: reason,
      refundStatus,
      refundId,
      refundGateway,
      refundAmount: isPaid ? amountRupees : 0,
      refundInitiatedAt: refundStatus === 'initiated' ? admin.firestore.FieldValue.serverTimestamp() : null
    });

    tx.delete(db.collection('deliveryQueue').doc(orderId));
  });

  return {
    ok: true,
    orderId,
    status: 'Cancelled',
    refundStatus,
    refundId,
    refundAmount: isPaid ? amountRupees : 0,
    message: refundStatus === 'initiated'
      ? `Order cancel हो गया है और ₹${amountRupees} का refund आपके UPI/Bank खाते में भेज दिया गया है (3–5 कार्यदिवसों में जमा हो जाएगा)।`
      : 'Order सफलतापूर्वक cancel हो गया है।'
  };
}

async function createPartnerDepositSession(uid, body) {
  const amountRupees = rupees(body.amount || 0);
  const paymentType = String(body.paymentType || 'COD_DEPOSIT').trim(); // 'COD_DEPOSIT' या 'KIT_FEE_DEPOSIT'
  const deductionIds = Array.isArray(body.deductionIds) ? body.deductionIds.map(String) : [];

  if (paise(amountRupees) < 100) {
    throw fail('Amount कम से कम ₹1 होना चाहिए।');
  }

  const partnerSnap = await db.collection('deliveryPartners').doc(uid).get();
  if (!partnerSnap.exists) {
    throw fail('Delivery Partner profile नहीं मिली।', 404);
  }

  const receiptId = `prt_${Date.now()}_${Math.floor(Math.random() * 1000)}`;
  const rOrder = await razorpay(
    'orders',
    'POST',
    {
      amount: paise(amountRupees),
      currency: 'INR',
      receipt: receiptId,
      notes: {
        partnerUid: uid,
        paymentType,
        deductionCount: String(deductionIds.length)
      }
    },
    RAZORPAY_KEY_SECRET.value()
  );

  await db.collection('partnerDepositSessions').doc(rOrder.id).set({
    razorpayOrderId: rOrder.id,
    partnerUid: uid,
    amountRupees,
    amountPaise: rOrder.amount,
    paymentType,
    deductionIds,
    status: 'created',
    createdAt: admin.firestore.FieldValue.serverTimestamp()
  });

  return {
    ok: true,
    keyId: String(RAZORPAY_KEY_ID.value() || '').trim(),
    razorpayOrderId: rOrder.id,
    amount: rOrder.amount
  };
}

async function verifyPartnerDeposit(uid, body) {
  const orderIdFromRzp = String(body.razorpayOrderId || '').trim();
  const paymentId = String(body.razorpayPaymentId || '').trim();
  const signature = String(body.razorpaySignature || '').trim();

  if (!orderIdFromRzp.startsWith('order_') || !paymentId.startsWith('pay_')) {
    throw fail('Payment verification data invalid है।');
  }

  const sessionRef = db.collection('partnerDepositSessions').doc(orderIdFromRzp);
  const sessionSnap = await sessionRef.get();
  if (!sessionSnap.exists) throw fail('Partner deposit session नहीं मिली।', 404);

  const session = sessionSnap.data();
  if (session.partnerUid !== uid) throw fail('यह session आपके खाते की नहीं है।', 403);
  if (session.status === 'paid') {
    return { ok: true, alreadyVerified: true, paymentId };
  }

  // HMAC Signature Verify
  const expected = crypto
    .createHmac('sha256', String(RAZORPAY_KEY_SECRET.value() || '').trim())
    .update(`${orderIdFromRzp}|${paymentId}`)
    .digest('hex');

  const a = Buffer.from(expected);
  const b = Buffer.from(signature);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) {
    throw fail('Payment signature सही नहीं है।', 401);
  }

  // Razorpay Server से Direct Verify & Capture
  const payment = await razorpay(`payments/${encodeURIComponent(paymentId)}`, 'GET', null, RAZORPAY_KEY_SECRET.value());
  if (payment.order_id !== orderIdFromRzp || Number(payment.amount) !== Number(session.amountPaise)) {
    throw fail('Payment amount/order mismatch है।', 409);
  }
  if (payment.status === 'authorized') {
    await razorpay(`payments/${encodeURIComponent(paymentId)}/capture`, 'POST', { amount: payment.amount, currency: 'INR' }, RAZORPAY_KEY_SECRET.value());
  }

  const partnerSnap = await db.collection('deliveryPartners').doc(uid).get();
  const partnerData = partnerSnap.data() || {};
  const branchId = String(partnerData.branchId || partnerData.storeId || '');
  const now = admin.firestore.FieldValue.serverTimestamp();
  const amountRupees = rupees(session.amountRupees);
  const breakdownItems = [];

  await db.runTransaction(async tx => {
    const freshSession = await tx.get(sessionRef);
    if (!freshSession.exists || freshSession.data().status === 'paid') return;

    // 1. अगर Kit/Fee जमा की है तो चुने हुए ledger items को paid मार्क करें
    const deductionIds = Array.isArray(session.deductionIds) ? session.deductionIds : [];
    for (const dId of deductionIds) {
      const dRef = db.collection('partnerRecoveryLedger').doc(String(dId));
      const dSnap = await tx.get(dRef);
      if (dSnap.exists) {
        const dData = dSnap.data();
        breakdownItems.push({
          id: dId,
          reason: String(dData.reason || 'Kit Fee'),
          note: String(dData.note || ''),
          amount: rupees(dData.amount || 0),
          addedByRole: String(dData.addedByRole || 'Admin')
        });
        tx.update(dRef, {
          status: 'paid_via_razorpay',
          razorpayPaymentId: paymentId,
          settledAt: now
        });
      }
    }

    // 2. अगर COD कैश जमा किया है तो codCashHandovers में approved एंट्री बनाएं
    if (session.paymentType === 'COD_DEPOSIT') {
      const codRef = db.collection('codCashHandovers').doc();
      tx.set(codRef, {
        partnerUid: uid,
        branchId,
        amount: amountRupees,
        paymentMode: 'Razorpay',
        razorpayOrderId: orderIdFromRzp,
        razorpayPaymentId: paymentId,
        status: 'approved',
        createdAt: now
      });
    }

    // 3. रसीद (Receipt) सेव करें ताकि Partner को पूरा हिसाब दिखे
    const receiptRef = db.collection('partnerPaymentReceipts').doc();
    tx.set(receiptRef, {
      partnerUid: uid,
      paymentType: session.paymentType,
      grossAmount: amountRupees,
      deductedAmount: 0,
      netAmount: amountRupees,
      breakdown: breakdownItems,
      razorpayOrderId: orderIdFromRzp,
      razorpayPaymentId: paymentId,
      status: 'SUCCESS',
      createdAt: now
    });

    tx.update(sessionRef, {
      status: 'paid',
      razorpayPaymentId: paymentId,
      verifiedAt: now
    });
  });

  return { ok: true, paymentId, amount: amountRupees };
}



exports.flashCartPayment = onRequest({region:REGION, secrets:[RAZORPAY_KEY_ID,RAZORPAY_KEY_SECRET,RAZORPAY_WEBHOOK_SECRET], timeoutSeconds:60, memory:'256MiB'}, async (req,res)=>{



  if (cors(req,res)) return;



  if (req.method!=='POST') return res.status(405).json({ok:false,error:'Method not allowed.'});



  try {



    const path=String(req.path||'').replace(/\/+$/,'');



    if (path==='/razorpay/webhook') {



      const sig=String(req.get('X-Razorpay-Signature')||'');



      const expected=crypto.createHmac('sha256',RAZORPAY_WEBHOOK_SECRET.value()).update(req.rawBody).digest('hex');



      const a=Buffer.from(expected), b=Buffer.from(sig); if (!sig || a.length!==b.length || !crypto.timingSafeEqual(a,b)) throw fail('Webhook signature invalid है।',401);



      const event=JSON.parse(req.rawBody.toString('utf8'));



      if (event.event==='payment.captured') {



        const p=event.payload?.payment?.entity||{};



        if (p.order_id && p.id) {



          const matches=await db.collection('paymentSessions').where('razorpayOrderId','==',p.order_id).limit(1).get();



          if (!matches.empty) { const sessionDoc=matches.docs[0], orderId=sessionDoc.id; if (sessionDoc.data().status!=='paid') await finalizePayment(sessionDoc.data().userId,{orderId,razorpayOrderId:p.order_id,razorpayPaymentId:p.id,razorpaySignature:crypto.createHmac('sha256',RAZORPAY_KEY_SECRET.value()).update(`${p.order_id}|${p.id}`).digest('hex')}); }



        }



      }



      return res.json({ok:true});



    }



    const uid=await requireUid(req);



    if (path==='/payment/native-session') return await createNativeSession(req,res,uid);



    if (path==='/order/cod-place') return res.json(await placeCodOrder(uid,req.body||{}));



    if (path==='/payment/native-verify') return res.json(await finalizePayment(uid,req.body||{}));
    if (path==='/partner/deposit-session') return res.json(await createPartnerDepositSession(uid,req.body||{}));
    if (path==='/partner/deposit-verify') return res.json(await verifyPartnerDeposit(uid,req.body||{}));



    return res.status(404).json({ok:false,error:'Not found.'});



  } catch(e) { const status=Number.isInteger(e.status)?e.status:500; if(status>=500) logger.error('FlashCart payment function failed',e); return res.status(status).json({ok:false,error:e.message||'Request failed.'}); }



});



const CASHFREE_CLIENT_ID = defineSecret('CASHFREE_CLIENT_ID');

const CASHFREE_CLIENT_SECRET = defineSecret('CASHFREE_CLIENT_SECRET');

const CASHFREE_ENV = defineString('CASHFREE_ENV', { default: 'SANDBOX' });

const CASHFREE_API_VERSION = '2025-01-01';



function cashfreeBaseUrl() {

  return String(CASHFREE_ENV.value() || 'SANDBOX').toUpperCase() === 'PRODUCTION'

    ? 'https://api.cashfree.com/pg'

    : 'https://sandbox.cashfree.com/pg';

}



async function cashfreeApi(path, method = 'GET', body = undefined) {
  const clientId = String(CASHFREE_CLIENT_ID.value() || '').trim();
  const clientSecret = String(CASHFREE_CLIENT_SECRET.value() || '').trim();
  const baseUrl = cashfreeBaseUrl();
  if (!clientId || !clientSecret) throw fail('Cashfree API keys configure नहीं हैं।', 500);
  const response = await fetch(`${baseUrl}${path}`, {
    method,
    headers: {
      'x-client-id': clientId,
      'x-client-secret': clientSecret,
      'x-api-version': CASHFREE_API_VERSION,
      'Content-Type': 'application/json',
      'Accept': 'application/json'
    },
    body: body === undefined ? undefined : JSON.stringify(body)
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    logger.error('Cashfree API failed', { path, status: response.status, data });
    throw fail(`Cashfree Error (${response.status}) [${baseUrl}] [ID:${clientId.slice(0, 6)}..]: ${data.message || data.code || 'अनुरोध पूरा नहीं हुआ'}`, 502);
  }
  return data;
}




function cashfreePhone(value) {

  const digits = String(value || '').replace(/\D/g, '');

  const ten = digits.length > 10 ? digits.slice(-10) : digits;

  if (!/^[6-9]\d{9}$/.test(ten)) throw fail('Cashfree के लिए ग्राहक का सही 10 अंकों का मोबाइल नंबर जरूरी है।');

  return ten;

}



async function createCashfreeOrder(req, res, uid) {

  const { orderId, orderData } = req.body || {};

  if (!safeId(orderId)) throw fail('Checkout ID सही नहीं है।');

  const sessionRef = db.collection('cashfreePaymentSessions').doc(orderId);

  const existing = await sessionRef.get();

  if (existing.exists) {

    const s = existing.data();

    if (s.userId !== uid) throw fail('यह checkout आपके खाते का नहीं है।', 403);

    if (s.status === 'created' && s.paymentSessionId && s.cashfreeOrderId) {

      return res.json({ ok: true, orderId: s.cashfreeOrderId, paymentSessionId: s.paymentSessionId, environment: CASHFREE_ENV.value(), reused: true });

    }

    throw fail('इस checkout की payment session पहले ही इस्तेमाल हो चुकी है। नया checkout शुरू करें।', 409);

  }



  const calc = await calculateOrder(uid, orderData);

  const phone = cashfreePhone(calc.userPhone);

  const cfOrderId = `fc\_${crypto.randomUUID().replace(/-/g, '').slice(0, 24)}`;

  const now = admin.firestore.FieldValue.serverTimestamp();

  const request = {

    order_id: cfOrderId,

    order_amount: rupees(calc.totalPrice),

    order_currency: 'INR',

    customer_details: {

      customer_id: String(uid).replace(/[^A-Za-z0-9\_-]/g, '').slice(0, 50) || `fc\_${Date.now()}`,

      customer_name: calc.customerName || 'FlashCart Customer',

      customer_phone: phone

    },

    order_note: `FlashCart grocery order ${orderId}`,

    order_meta: {

      return_url: `https://flashcarts.in/payment-return?order_id=${encodeURIComponent(cfOrderId)}`

    }

  };

  const created = await cashfreeApi('/orders', 'POST', request);

  if (!created.payment_session_id || !created.order_id) throw fail('Cashfree ने Payment Session ID नहीं दिया।', 502);



  const savedOrderData = {

    orderId, userId: uid, userPhone: calc.userPhone, customerName: calc.customerName,

    items: calc.items, itemsTotal: calc.itemsTotal,

    handlingProcessingFee: calc.handlingProcessingFee, packagingFee: calc.packagingFee,

    deliveryFee: calc.deliveryFee, discountAmount: calc.discountAmount,

    discountPercent: calc.discountPercent, appliedOfferCode: calc.appliedOfferCode,

    appliedOfferName: calc.appliedOfferName, totalPrice: calc.totalPrice,

    paymentMethod: 'Cashfree', paymentStatus: 'paid',

    deliveryAddress: calc.deliveryAddress,

    deliveryLatitude: calc.deliveryLatitude, deliveryLongitude: calc.deliveryLongitude,

    deliveryGeoPoint: new admin.firestore.GeoPoint(calc.deliveryLatitude, calc.deliveryLongitude),

    deliveryLocationSet: true, deliveryLocationUpdatedAt: now,

    branchId: calc.branch.id, branchName: calc.branch.name,

    branchLatitude: calc.branch.lat, branchLongitude: calc.branch.lng,

    serviceRadiusKm: calc.branch.radius,

    deliveryDistanceKm: Number(calc.branch.distance.toFixed(3)),

    status: 'Order Placed', orderDate: now

  };

  await sessionRef.create({

    orderId, userId: uid, status: 'created', paymentStatus: 'pending',

    cashfreeOrderId: created.order_id, paymentSessionId: created.payment_session_id,

    amount: rupees(calc.totalPrice), currency: 'INR', environment: CASHFREE_ENV.value(),

    orderData: savedOrderData, createdAt: now

  });

 
  return res.json({ ok: true, orderId: created.order_id, paymentSessionId: created.payment_session_id, environment: CASHFREE_ENV.value() });

}



async function finalizeCashfreePayment(uid, orderId) {

  if (!safeId(orderId)) throw fail('Checkout ID सही नहीं है।');

  const sessionRef = db.collection('cashfreePaymentSessions').doc(orderId);

  const sessionSnap = await sessionRef.get();

  if (!sessionSnap.exists) throw fail('Cashfree payment session नहीं मिली।', 404);

  const session = sessionSnap.data();

  if (uid && session.userId !== uid) throw fail('यह payment session आपके खाते का नहीं है।', 403);



  // Always ask Cashfree's server API; never trust the Flutter callback/webview result.

  const cfOrder = await cashfreeApi(`/orders/${encodeURIComponent(session.cashfreeOrderId)}`);

  if (String(cfOrder.order_status || '').toUpperCase() !== 'PAID') {

    return { ok: true, orderId, paymentStatus: String(cfOrder.order_status || 'PENDING').toLowerCase(), orderCreated: false };

  }

  if (Number(cfOrder.order_amount) !== Number(session.amount) || cfOrder.order_currency !== 'INR') {

    throw fail('Cashfree payment amount/currency mismatch है।', 409);

  }



  const orderRef = db.collection('orders').doc(orderId);

  const queueRef = db.collection('deliveryQueue').doc(orderId);

  await db.runTransaction(async tx => {

    const [freshSession, existingOrder] = await Promise.all([tx.get(sessionRef), tx.get(orderRef)]);

    if (!freshSession.exists) throw fail('Cashfree payment session नहीं मिली।', 404);

    const fresh = freshSession.data();

    if (uid && fresh.userId !== uid) throw fail('Payment user mismatch है।', 403);

    if (existingOrder.exists && existingOrder.data().paymentStatus === 'paid') {

      tx.update(sessionRef, { status: 'paid', paymentStatus: 'paid', verifiedAt: admin.firestore.FieldValue.serverTimestamp() });

      return;

    }

    const data = fresh.orderData;

    const quantities = new Map();

    for (const item of data.items) quantities.set(item.productId, (quantities.get(item.productId) || 0) + item.quantity);

    const productSnaps = [];

    for (const [id, qty] of quantities) {

      const ref = db.collection('products').doc(id);

      const snap = await tx.get(ref);

      if (!snap.exists || snap.data().available === false || Number(snap.data().stock || 0) < qty) {

        throw fail('Payment हो गया, लेकिन stock conflict है। Support से संपर्क करें।', 409);

      }

      productSnaps.push({ ref, qty });

    }

    for (const p of productSnaps) tx.update(p.ref, { stock: admin.firestore.FieldValue.increment(-p.qty) });

    tx.set(orderRef, {

      ...data,

      cashfreeOrderId: fresh.cashfreeOrderId,

      paymentGateway: 'cashfree', paymentMethod: 'Cashfree',

      paymentStatus: 'paid', paymentVerifiedAt: admin.firestore.FieldValue.serverTimestamp()

    });

    tx.set(queueRef, {

      orderId, userId: fresh.userId, status: 'pending', assignedPartnerId: '',

      paymentMethod: 'Cashfree', paymentStatus: 'paid',

      branchId: data.branchId, branchName: data.branchName,

      createdAt: admin.firestore.FieldValue.serverTimestamp()

    });

    tx.update(sessionRef, {

      status: 'paid', paymentStatus: 'paid',

      verifiedAt: admin.firestore.FieldValue.serverTimestamp()

    });

  });

  return { ok: true, orderId, paymentStatus: 'paid', orderCreated: true };

}



function verifyCashfreeWebhook(req) {

  const signature = String(req.get('x-webhook-signature') || '');

  const timestamp = String(req.get('x-webhook-timestamp') || '');

  if (!signature || !timestamp || !req.rawBody) return false;

  const expected = crypto.createHmac('sha256', CASHFREE_CLIENT_SECRET.value())

    .update(timestamp + req.rawBody.toString('utf8'))

    .digest('base64');

  const a = Buffer.from(expected);

  const b = Buffer.from(signature);

  return a.length === b.length && crypto.timingSafeEqual(a, b);

}



exports.cashfreePayment = onRequest({
  region: REGION,
  secrets: [CASHFREE_CLIENT_ID, CASHFREE_CLIENT_SECRET, RAZORPAY_KEY_ID, RAZORPAY_KEY_SECRET],
  timeoutSeconds: 60,
  memory: '256MiB'
}, async (req, res) => {
  res.set('Access-Control-Allow-Origin', '*');
  res.set('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.set('Access-Control-Allow-Headers', 'Content-Type, Authorization, x-webhook-signature, x-webhook-timestamp');
  res.set('Cache-Control', 'no-store');
  if (req.method === 'OPTIONS') return res.status(204).send('');
  if (req.method !== 'POST') return res.status(405).json({ ok: false, error: 'Method not allowed.' });
  try {
    const path = String(req.path || '').replace(/\/+$/, '');
    if (path === '/webhook') {
      if (!verifyCashfreeWebhook(req)) throw fail('Cashfree webhook signature invalid है।', 401);
      const event = JSON.parse(req.rawBody.toString('utf8'));
      const orderId = String(event?.data?.order?.order_id || '');
      const type = String(event?.type || '');
      if (orderId && (type.includes('PAYMENT_SUCCESS') || type.includes('ORDER_PAID'))) {
        const match = await db.collection('cashfreePaymentSessions').where('cashfreeOrderId', '==', orderId).limit(1).get();
        if (!match.empty) await finalizeCashfreePayment(match.docs[0].data().userId, match.docs[0].id);
      }
      return res.json({ ok: true });
    }
    const uid = await requireUid(req);
    if (path === '/payment/create-order') return await createCashfreeOrder(req, res, uid);
    if (path === '/payment/verify') return res.json(await finalizeCashfreePayment(uid, String((req.body || {}).orderId || '')));
    if (path === '/order/cancel-refund') return res.json(await cancelAndRefundOrder(uid, req.body || {}));
    return res.status(404).json({ ok: false, error: 'Not found.' });
  } catch (e) {
    const status = Number.isInteger(e.status) ? e.status : 500;
    if (status >= 500) logger.error('Cashfree payment function failed', e);
    return res.status(status).json({ ok: false, error: e.message || 'Request failed.' });
  }
});
