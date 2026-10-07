/**
 * Firestore security rules tests.
 *
 * Run with the emulator (never against production):
 *
 *   firebase emulators:start --only firestore
 *   cd rules-tests && npm install && npm test
 *
 * Mirrors the test cases required by the project instructions:
 * unauthenticated / owner / non-owner / admin-less world, malformed data,
 * modified ownership fields, modified status, modified price, duplicates.
 */
const fs = require("fs");
const path = require("path");
const {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} = require("@firebase/rules-unit-testing");
const {
  collection,
  getCountFromServer,
  query,
  serverTimestamp,
  where,
} = require("firebase/firestore");

let env;

// Fixed uids so conversation ids are deterministic.
const CLIENT = "client-uid";
const FREELANCER = "freelancer-uid";
const STRANGER = "stranger-uid";
const ADMIN = "admin-uid";
const CONVO_ID = "client-uid_freelancer-uid";

/** A verified UM account. Every rule builds on isSignedIn(), which requires
 *  a verified @umindanao.edu.ph address, so the fixture identities carry one
 *  in the student format (initial.surname.123456). */
function umEmail(uid) {
  const digits = String(Math.abs(hash(uid))).padStart(6, '0').slice(0, 6);
  return `${uid.replace(/[^a-z]/g, '').slice(0, 1) || 'a'}.${uid.replace(/[^a-z]/g, '') || 'user'}.${digits}@umindanao.edu.ph`;
}

function hash(text) {
  let h = 0;
  for (const c of text) h = (h * 31 + c.charCodeAt(0)) | 0;
  return h;
}

function authed(uid, claims = {}) {
  return env
    .authenticatedContext(uid, {
      email: umEmail(uid),
      email_verified: true,
      ...claims,
    })
    .firestore();
}

/** A signed-in account from outside the university domain. */
function outsider(uid) {
  return env
    .authenticatedContext(uid, { email: `${uid}@gmail.com`, email_verified: true })
    .firestore();
}

function unauthed() {
  return env.unauthenticatedContext().firestore();
}

async function seedPublishedService() {
  await env.withSecurityRulesDisabled(async (ctx) => {
    // One handle per block: calling ctx.firestore() twice re-applies settings
    // to an already-started instance and throws.
    const db = ctx.firestore();
    await db
      .doc(`services/service1`)
      .set({
        sellerId: FREELANCER,
        title: "Tutoring",
        titleLower: "tutoring",
        description: "I will help you pass calculus exams.",
        categoryId: "tutoring",
        skills: ["math"],
        startingPrice: 500,
        currency: "PHP",
        deliveryDays: 3,
        revisionCount: 1,
        status: "published",
        ratingSum: 0,
        ratingCount: 0,
        // Real listings always carry createdAt; the update rule pins it.
        createdAt: new Date("2026-01-01T00:00:00Z"),
      });
    // Real profiles always carry createdAt; the update rule pins it.
    // Both adults: selling and payouts are age-gated.
    await db.doc(`users/${CLIENT}`).set({
      uid: CLIENT,
      displayName: "Client",
      bio: "",
      skills: [],
      birthDate: new Date("2000-01-01T00:00:00Z"),
      createdAt: new Date("2026-01-01T00:00:00Z"),
    });
    await db.doc(`users/${FREELANCER}`).set({
      uid: FREELANCER,
      displayName: "Freelancer",
      bio: "",
      skills: [],
      birthDate: new Date("2000-01-01T00:00:00Z"),
      createdAt: new Date("2026-01-01T00:00:00Z"),
    });
    // A completed order used for review tests.
    await db.doc(`orders/order1`).set({
      serviceId: "service1",
      serviceTitle: "Tutoring",
      clientId: CLIENT,
      freelancerId: FREELANCER,
      participantIds: [CLIENT, FREELANCER],
      price: 500,
      currency: "PHP",
      deliveryDays: 3,
      revisionCount: 1,
      requirements: "Please help me with derivatives and limits.",
      status: "completed",
    });
    // An accepted order — the state in which payment is allowed to open.
    await db.doc(`orders/order2`).set({
      serviceId: "service1",
      serviceTitle: "Tutoring",
      clientId: CLIENT,
      freelancerId: FREELANCER,
      participantIds: [CLIENT, FREELANCER],
      price: 500,
      currency: "PHP",
      deliveryDays: 3,
      revisionCount: 1,
      requirements: "Please help me with derivatives and limits.",
      status: "accepted",
    });
  });
}

/** A well-formed payment for the accepted order2: 500 = 25 + 475. */
function validPayment(overrides = {}) {
  return {
    orderId: "order2",
    clientId: CLIENT,
    freelancerId: FREELANCER,
    participantIds: [CLIENT, FREELANCER],
    amount: 500,
    currency: "PHP",
    commission: 25,
    netToFreelancer: 475,
    status: "pending",
    method: "manual",
    verified: false,
    ...overrides,
  };
}

/** Writes a pending payment straight past the rules, for update tests. */
async function seedPendingPayment(overrides = {}) {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx.firestore().doc("payments/order2").set(validPayment(overrides));
  });
}

before(async () => {
  env = await initializeTestEnvironment({
    projectId: "rules-test",
    firestore: {
      // Matches firebase.json; stated here because the suite runs from this
      // directory, where auto-discovery cannot find that file.
      host: process.env.FIRESTORE_EMULATOR_HOST?.split(":")[0] || "127.0.0.1",
      port: Number(process.env.FIRESTORE_EMULATOR_HOST?.split(":")[1]) || 8080,
      rules: fs.readFileSync(path.join(__dirname, "../firestore.rules"), "utf8"),
    },
  });
});

beforeEach(async () => {
  await env.clearFirestore();
  await seedPublishedService();
});

after(async () => {
  await env.cleanup();
});

describe("authentication boundary", () => {
  it("denies anonymous reads of services", async () => {
    await assertFails(unauthed().collection("services").get());
  });

  it("denies a non-UM Google account everything, even its own profile", async () => {
    await assertFails(outsider("gmail-user").collection("services").get());
    await assertFails(outsider("gmail-user").doc("services/service1").get());
    await assertFails(
      outsider("gmail-user").doc("users/gmail-user").set({
        uid: "gmail-user",
        displayName: "Outsider",
        bio: "",
        skills: [],
        createdAt: new Date(),
      })
    );
  });

  it("denies an unverified UM address", async () => {
    const unverified = env
      .authenticatedContext("unv", { email: "a.unv.123456@umindanao.edu.ph", email_verified: false })
      .firestore();
    await assertFails(unverified.collection("services").get());
  });

  it("a profile may claim the token's address and student number, and nothing else", async () => {
    const me = authed("new-student").doc("users/new-student");
    const email = umEmail("new-student");
    const studentId = email.split("@")[0].split(".")[2];
    await assertSucceeds(
      me.set({
        uid: "new-student",
        displayName: "New",
        bio: "",
        skills: [],
        email,
        studentId,
        identityVerified: true,
        createdAt: new Date(),
      })
    );
    await assertFails(
      authed("other-student").doc("users/other-student").set({
        uid: "other-student",
        displayName: "Other",
        bio: "",
        skills: [],
        email: "someone.else.999999@umindanao.edu.ph",
        createdAt: new Date(),
      })
    );
    await assertFails(
      authed("third").doc("users/third").set({
        uid: "third",
        displayName: "Third",
        bio: "",
        skills: [],
        studentId: "000000",
        createdAt: new Date(),
      })
    );
    // The address is pinned afterwards.
    await assertFails(me.update({ email: "a.other.111111@umindanao.edu.ph" }));
  });

  it("a non-student UM address (faculty) cannot claim identityVerified", async () => {
    const faculty = env
      .authenticatedContext("prof", { email: "registrar@umindanao.edu.ph", email_verified: true })
      .firestore();
    await assertFails(
      faculty.doc("users/prof").set({
        uid: "prof",
        displayName: "Registrar",
        bio: "",
        skills: [],
        identityVerified: true,
        createdAt: new Date(),
      })
    );
    await assertSucceeds(
      faculty.doc("users/prof").set({
        uid: "prof",
        displayName: "Registrar",
        bio: "",
        skills: [],
        createdAt: new Date(),
      })
    );
  });

  it("denies anonymous reads of profiles", async () => {
    await assertFails(unauthed().doc(`users/${CLIENT}`).get());
  });

  it("denies anonymous reads of orders", async () => {
    await assertFails(unauthed().doc("orders/order1").get());
  });

  it("denies listing all users (directory scraping)", async () => {
    await assertFails(authed(STRANGER).collection("users").get());
  });
});

describe("services", () => {
  const validService = {
    sellerId: FREELANCER,
    title: "Logo design",
    titleLower: "logo design",
    description: "I design clean minimal logos for student orgs.",
    categoryId: "design",
    skills: [],
    startingPrice: 300,
    currency: "PHP",
    deliveryDays: 2,
    revisionCount: 2,
    status: "draft",
    // Matches the full payload sent by FreelanceService.toFirestore().
    pricingMode: "fixed",
    requiresContact: false,
    ratingSum: 0,
    ratingCount: 0,
    // The update rule pins createdAt; real documents always carry one.
    createdAt: new Date("2026-01-01T00:00:00Z"),
  };

  it("lets a user create their own valid service", async () => {
    await assertSucceeds(
      authed(FREELANCER).doc("services/svc2").set(validService)
    );
  });

  it("accepts the editor's pricing fields but keeps their values closed", async () => {
    await assertSucceeds(
      authed(FREELANCER).doc("services/svc-pricing").set({
        ...validService,
        pricingMode: "negotiable",
        requiresContact: true,
      })
    );
    await assertFails(
      authed(FREELANCER).doc("services/svc-bad-pricing").set({
        ...validService,
        pricingMode: "auction",
      })
    );
    await assertFails(
      authed(FREELANCER).doc("services/svc-bad-contact").set({
        ...validService,
        requiresContact: "yes",
      })
    );
  });

  it("rejects creating a service owned by someone else", async () => {
    await assertFails(
      authed(STRANGER)
        .doc("services/svc3")
        .set({ ...validService, sellerId: FREELANCER })
    );
  });

  it("rejects prices outside the allowed range", async () => {
    await assertFails(
      authed(FREELANCER)
        .doc("services/svc4")
        .set({ ...validService, startingPrice: 0 })
    );
    await assertFails(
      authed(FREELANCER)
        .doc("services/svc4")
        .set({ ...validService, startingPrice: 2000000 })
    );
  });

  it("blocks transferring ownership or forging ratings on update", async () => {
    await authed(FREELANCER).doc("services/svc5").set(validService);
    await assertFails(
      authed(FREELANCER).doc("services/svc5").update({ sellerId: STRANGER })
    );
    await assertFails(
      authed(FREELANCER).doc("services/svc5").update({ ratingSum: 999 })
    );
    await assertSucceeds(
      authed(FREELANCER).doc("services/svc5").update({ status: "published" })
    );
  });

  it("hides drafts from other users' gets", async () => {
    await assertFails(authed(CLIENT).doc("services/svc5").get());
  });
});

describe("orders", () => {
  function orderCreate(price = 500, buyer = CLIENT, freelancer = FREELANCER) {
    return {
      serviceId: "service1",
      serviceTitle: "Tutoring",
      clientId: buyer,
      freelancerId: freelancer,
      participantIds: [buyer, freelancer].sort(),
      price,
      currency: "PHP",
      deliveryDays: 3,
      revisionCount: 1,
      requirements: "Please help me with derivatives and limits.",
      status: "pending",
    };
  }

  it("allows ordering at exactly the service price", async () => {
    await assertSucceeds(
      authed(CLIENT).collection("orders").add(orderCreate())
    );
  });

  it("rejects manipulated prices (₱500 service ordered at ₱1)", async () => {
    await assertFails(authed(CLIENT).collection("orders").add(orderCreate(1)));
  });

  it("rejects ordering your own service", async () => {
    await assertFails(
      authed(FREELANCER)
        .collection("orders")
        .add(orderCreate(500, FREELANCER, FREELANCER))
    );
  });

  it("rejects an injected third participant", async () => {
    await assertFails(
      authed(CLIENT).collection("orders").add({
        ...orderCreate(),
        participantIds: [CLIENT, FREELANCER, STRANGER],
      })
    );
  });

  it("rejects spoofing the client id on create", async () => {
    await assertFails(
      authed(STRANGER).collection("orders").add(orderCreate(500))
    );
  });

  it("freezes price and participants after creation", async () => {
    const ref = await authed(CLIENT)
      .collection("orders")
      .add(orderCreate());
    await assertFails(authed(CLIENT).doc(ref.path).update({ price: 1 }));
    await assertFails(
      authed(CLIENT).doc(ref.path).update({
        participantIds: [CLIENT, STRANGER],
      })
    );
  });

  it("enforces role-gated transitions", async () => {
    const docRef = await authed(CLIENT).collection("orders").add(orderCreate());

    // Client cannot accept their own pending request.
    await assertFails(docRef.update({ status: "accepted" }));
    // Freelancer accepts.
    const asFreelancer = authed(FREELANCER).doc(`orders/${docRef.id}`);
    await assertSucceeds(asFreelancer.update({ status: "accepted" }));

    // Illegal jump accepted -> submitted.
    await assertFails(docRef.update({ status: "submitted" }));
    await assertFails(asFreelancer.update({ status: "inProgress" }));
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc(`payments/${docRef.id}`).set({
        ...validPayment({ orderId: docRef.id }),
        status: "paid",
      });
    });
    await assertSucceeds(asFreelancer.update({ status: "inProgress" }));
    await assertSucceeds(
      asFreelancer.update({ status: "submitted" })
    );

    // The freelancer may not complete their own delivery…
    await assertFails(
      asFreelancer.update({ status: "completed" })
    );
    // …only the client can, and completed is terminal.
    await assertSucceeds(docRef.update({ status: "completed" }));
    await assertFails(docRef.update({ status: "inProgress" }));
  });

  it("hides orders from strangers", async () => {
    await assertFails(authed(STRANGER).doc("orders/order1").get());
  });
});

describe("chat", () => {
  beforeEach(async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc(`conversations/${CONVO_ID}`).set({
        participantIds: [CLIENT, FREELANCER],
        lastMessagePreview: "",
        lastMessageSenderId: "",
        // The update rule pins createdAt, so a faithful fixture needs one.
        createdAt: new Date("2026-01-01T00:00:00Z"),
      });
    });
  });

  it("lets participants read messages but strangers cannot", async () => {
    await assertSucceeds(
      authed(CLIENT).collection(`conversations/${CONVO_ID}/messages`).get()
    );
    await assertFails(
      authed(STRANGER).collection(`conversations/${CONVO_ID}/messages`).get()
    );
    await assertFails(
      unauthed().collection(`conversations/${CONVO_ID}/messages`).get()
    );
  });

  it("rejects sender spoofing and oversized or empty messages", async () => {
    const messages = authed(CLIENT).collection(
      `conversations/${CONVO_ID}/messages`
    );
    await assertFails(messages.add({ senderId: FREELANCER, text: "hi" }));
    await assertFails(
      messages.add({ senderId: CLIENT, text: "x".repeat(2500) })
    );
    await assertFails(messages.add({ senderId: CLIENT, text: "" }));
    await assertSucceeds(
      messages.add({ senderId: CLIENT, text: "hello!" })
    );
  });

  it("shares the seller's service with both participants and rejects forged context", async () => {
    const messages = authed(CLIENT).collection(`conversations/${CONVO_ID}/messages`);
    const contextual = { senderId: CLIENT, text: "I am interested", serviceId: "service1", serviceTitle: "Tutoring" };
    const ref = await assertSucceeds(messages.add(contextual));
    await assertSucceeds(authed(FREELANCER).doc(ref.path).get());
    await assertFails(authed(STRANGER).doc(ref.path).get());
    await assertFails(messages.add({ ...contextual, serviceTitle: "Forged title" }));
    await assertFails(messages.add({ ...contextual, serviceId: "missing" }));
    await assertFails(messages.add({ ...contextual, serviceId: "service1/other" }));
    await assertFails(messages.add({ senderId: CLIENT, text: "hello", serviceTitle: "Tutoring" }));
    await assertFails(messages.add({ senderId: CLIENT, text: "hello", serviceId: "service1" }));
    await assertFails(messages.add({ ...contextual, text: "" }));
    await assertFails(authed(FREELANCER).collection(`conversations/${CONVO_ID}/messages`)
      .add({ ...contextual, senderId: FREELANCER }));
    await env.withSecurityRulesDisabled(async (ctx) => {
      const db = ctx.firestore();
      await db.doc('services/unrelated').set({ sellerId: STRANGER, status: 'published', title: 'Unrelated' });
      await db.doc('services/paused').set({ sellerId: FREELANCER, status: 'paused', title: 'Paused' });
    });
    await assertFails(messages.add({ ...contextual, serviceId: 'unrelated', serviceTitle: 'Unrelated' }));
    await assertFails(messages.add({ ...contextual, serviceId: 'paused', serviceTitle: 'Paused' }));
    await assertSucceeds(messages.add({ senderId: CLIENT, text: 'Normal profile-origin message' }));
  });

  it("keeps messages immutable", async () => {
    const ref = await authed(CLIENT)
      .collection(`conversations/${CONVO_ID}/messages`)
      .add({ senderId: CLIENT, text: "hello!" });
    await assertFails(ref.update({ text: "edited" }));
    await assertFails(ref.delete());
  });

  it("blocks membership changes on conversations", async () => {
    await assertFails(
      authed(CLIENT).doc(`conversations/${CONVO_ID}`).update({
        participantIds: [CLIENT, STRANGER],
      })
    );
    await assertSucceeds(
      authed(CLIENT)
        .doc(`conversations/${CONVO_ID}`)
        .update({ lastMessagePreview: "updated preview" })
    );
  });
});

describe("reviews", () => {
  it("lets only the client of a completed order review once", async () => {
    const review = {
      orderId: "order1",
      serviceId: "service1",
      reviewerId: CLIENT,
      revieweeId: FREELANCER,
      rating: 5,
      comment: "Great tutor, very patient.",
    };

    await assertSucceeds(authed(CLIENT).doc("reviews/order1").set(review));
    // Duplicate review: same document id already exists with different content.
    await assertFails(
      authed(CLIENT).doc("reviews/order1").set({ ...review, comment: "again" })
    );
    // Spoofed reviewer.
    await assertFails(
      authed(STRANGER).doc("reviews/order2").set({
        ...review,
        orderId: "order2",
        reviewerId: CLIENT,
      })
    );
    // Reviews are immutable.
    await assertFails(authed(CLIENT).doc("reviews/order1").update({ rating: 1 }));
  });

  it("rejects reviews on orders that are not completed", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc("orders/order-pending").set({
        serviceId: "service1",
        serviceTitle: "Tutoring",
        clientId: CLIENT,
        freelancerId: FREELANCER,
        participantIds: [CLIENT, FREELANCER],
        price: 500,
        status: "pending",
      });
    });
    await assertFails(
      authed(CLIENT).doc("reviews/order-pending").set({
        orderId: "order-pending",
        serviceId: "service1",
        reviewerId: CLIENT,
        revieweeId: FREELANCER,
        rating: 5,
        comment: "Never even started yet!",
      })
    );
  });

  it("rejects a review that points a completed order at another service", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc("services/service2").set({
        sellerId: FREELANCER,
        title: "Other service",
        titleLower: "other service",
        description: "Another listing entirely, twenty chars plus.",
        categoryId: "other",
        skills: [],
        startingPrice: 100,
        currency: "PHP",
        deliveryDays: 1,
        revisionCount: 0,
        status: "published",
        ratingSum: 0,
        ratingCount: 0,
      });
    });
    const db = authed(CLIENT);
    const batch = db.batch();
    batch.set(db.doc("reviews/order1"), {
      orderId: "order1",
      serviceId: "service2",
      reviewerId: CLIENT,
      revieweeId: FREELANCER,
      rating: 5,
      comment: "This must stay attached to the ordered service.",
    });
    batch.update(db.doc("services/service2"), {
      ratingSum: 5,
      ratingCount: 1,
      lastReviewId: "order1",
    });
    await assertFails(batch.commit());
  });
});

describe("notifications", () => {
  beforeEach(async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc(`conversations/${CONVO_ID}`).set({
        participantIds: [CLIENT, FREELANCER],
        lastMessagePreview: "",
        lastMessageSenderId: "",
      });
    });
  });

  const baseNotification = {
    type: "chat.message",
    title: "New message",
    body: "",
    read: false,
    conversationId: CONVO_ID,
  };

  it("lets a conversation participant notify the other participant", async () => {
    await assertSucceeds(
      authed(CLIENT)
        .collection(`users/${FREELANCER}/notifications`)
        .add(baseNotification)
    );
  });

  it("rejects notifying someone outside the sender's conversation", async () => {
    await assertFails(
      authed(STRANGER)
        .collection(`users/${FREELANCER}/notifications`)
        .add(baseNotification)
    );
  });

  it("rejects oversized titles or pre-read notifications", async () => {
    const target = authed(FREELANCER).collection(
      `users/${FREELANCER}/notifications`
    );
    await assertFails(
      target.add({
        ...baseNotification,
        title: "x".repeat(141),
      })
    );
    await assertFails(target.add({ ...baseNotification, read: true }));
  });

  it("lets recipients flip `read` and nothing else", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx
        .firestore()
        .doc(`users/${CLIENT}/notifications/n1`)
        .set({ type: "chat.message", title: "t", body: "", read: false });
    });
    await assertSucceeds(
      authed(CLIENT)
        .doc(`users/${CLIENT}/notifications/n1`)
        .update({ read: true })
    );
    await assertFails(
      authed(CLIENT)
        .doc(`users/${CLIENT}/notifications/n1`)
        .update({ title: "spoofed" })
    );
    await assertFails(
      authed(STRANGER).doc(`users/${CLIENT}/notifications/n1`).get()
    );
  });

  it("restricts review.received to the buyer of the completed order", async () => {
    // order1 is completed; its client may notify the freelancer…
    await assertSucceeds(
      authed(CLIENT)
        .collection(`users/${FREELANCER}/notifications`)
        .add({
          type: "review.received",
          title: "You received a new review",
          body: "",
          read: false,
          orderId: "order1",
        })
    );
    // …but the freelancer cannot use that channel on themselves.
    await assertFails(
      authed(FREELANCER)
        .collection(`users/${FREELANCER}/notifications`)
        .add({
          type: "review.received",
          title: "fake",
          body: "",
          read: false,
          orderId: "order1",
        })
    );
  });
});

describe("payments", () => {
  it("lets the buyer open a payment for an accepted order", async () => {
    await assertSucceeds(
      authed(CLIENT).doc("payments/order2").set(validPayment())
    );
  });

  it("stops the freelancer from opening a payment against themselves", async () => {
    await assertFails(
      authed(FREELANCER).doc("payments/order2").set(validPayment())
    );
  });

  it("hides payments from everyone but the two parties", async () => {
    await seedPendingPayment();
    await assertSucceeds(authed(CLIENT).doc("payments/order2").get());
    await assertSucceeds(authed(FREELANCER).doc("payments/order2").get());
    await assertFails(authed(STRANGER).doc("payments/order2").get());
    await assertFails(unauthed().doc("payments/order2").get());
  });

  // Regression: the payment document does not exist until the buyer pays, so
  // the read that the order screen issues on open landed on a missing
  // document. A rule that reached into resource.data raised a null error
  // there, which reaches the client as permission-denied — every unpaid order
  // reported "Could not load payment details" to both parties.
  it("lets both parties read the payment that does not exist yet", async () => {
    await assertSucceeds(authed(CLIENT).doc("payments/order2").get());
    await assertSucceeds(authed(FREELANCER).doc("payments/order2").get());
  });

  it("still hides the unpaid slot from outsiders", async () => {
    await assertFails(authed(STRANGER).doc("payments/order2").get());
    await assertFails(unauthed().doc("payments/order2").get());
  });

  it("refuses the unpaid slot of an order that does not exist", async () => {
    await assertFails(authed(CLIENT).doc("payments/no-such-order").get());
  });

  it("rejects paying less than the order is worth", async () => {
    // The classic price-manipulation attempt: ₱1 for a ₱500 order.
    await assertFails(
      authed(CLIENT)
        .doc("payments/order2")
        .set(validPayment({ amount: 1, commission: 0, netToFreelancer: 1 }))
    );
  });

  it("rejects a split that does not reconstitute the gross", async () => {
    // Invented money: 500 paid, but 500 + 450 claimed as distributed.
    await assertFails(
      authed(CLIENT)
        .doc("payments/order2")
        .set(validPayment({ commission: 500, netToFreelancer: 450 }))
    );
  });

  it("rejects a manual payment that forges the platform commission", async () => {
    await assertFails(
      authed(CLIENT)
        .doc("payments/order2")
        .set(validPayment({ commission: 0, netToFreelancer: 500 }))
    );
  });


  it("rejects the previous 10 percent split on new payments", async () => {
    await assertFails(
      authed(CLIENT).doc("payments/order2")
        .set(validPayment({ commission: 50, netToFreelancer: 450 }))
    );
  });

  it("rejects a payment that injects another participant", async () => {
    await assertFails(
      authed(CLIENT)
        .doc("payments/order2")
        .set(validPayment({ participantIds: [CLIENT, FREELANCER, STRANGER] }))
    );
  });

  it("refuses a payment that claims to be already settled", async () => {
    await assertFails(
      authed(CLIENT).doc("payments/order2").set(validPayment({ status: "paid" }))
    );
  });

  it("refuses a client-asserted gateway verification", async () => {
    // 'verified' means "a trusted server checked this with the gateway".
    await assertFails(
      authed(CLIENT).doc("payments/order2").set(validPayment({ verified: true }))
    );
  });

  it("will not open a payment before the freelancer accepts", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc("orders/order2").update({ status: "pending" });
    });
    await assertFails(
      authed(CLIENT).doc("payments/order2").set(validPayment())
    );
  });

  it("lets the freelancer confirm they received the money", async () => {
    await seedPendingPayment();
    await assertSucceeds(
      authed(FREELANCER)
        .doc("payments/order2")
        .update({ status: "paid", verified: false })
    );
  });

  it("stops the payer confirming their own payment", async () => {
    // The whole value of the attestation is that the recipient makes it.
    await seedPendingPayment();
    await assertFails(
      authed(CLIENT).doc("payments/order2").update({ status: "paid" })
    );
  });

  it("stops a manual confirmation masquerading as gateway-verified", async () => {
    await seedPendingPayment();
    await assertFails(
      authed(FREELANCER)
        .doc("payments/order2")
        .update({ status: "paid", verified: true })
    );
  });

  it("keeps the gateway's invoice id out of the payer's hands", async () => {
    // The backend writes gatewayReference and later asks Xendit about that
    // invoice. A payer who could point it elsewhere could steer what the
    // sync and the reconciler look up. Their own note is still theirs.
    await seedPendingPayment();
    await assertFails(
      authed(CLIENT)
        .doc("payments/order2")
        .update({ gatewayReference: "inv_someone_elses" })
    );
    await assertSucceeds(
      authed(CLIENT).doc("payments/order2").update({ reference: "GCash ref 123" })
    );
  });

  it("freezes the amount and the split after creation", async () => {
    await seedPendingPayment();
    await assertFails(
      authed(CLIENT).doc("payments/order2").update({ amount: 5 })
    );
    await assertFails(
      authed(FREELANCER).doc("payments/order2").update({ commission: 0 })
    );
    await assertFails(
      authed(CLIENT).doc("payments/order2").update({ netToFreelancer: 500 })
    );
  });

  it("settles an existing payment without changing its historical split", async () => {
    await seedPendingPayment({ commission: 50, netToFreelancer: 450 });
    await assertSucceeds(
      authed(FREELANCER).doc("payments/order2").update({ status: "paid" })
    );
    const settled = await authed(FREELANCER).doc("payments/order2").get();
    if (settled.data().commission !== 50 || settled.data().netToFreelancer !== 450) {
      throw new Error("Historical split changed during settlement");
    }
  });

  it("cannot be re-opened once settled", async () => {
    await seedPendingPayment({ status: "paid" });
    await assertFails(
      authed(CLIENT).doc("payments/order2").update({ status: "pending" })
    );
    await assertFails(
      authed(FREELANCER).doc("payments/order2").update({ status: "pending" })
    );
  });

  it("keeps payment history as permanent dispute evidence", async () => {
    await seedPendingPayment();
    await assertFails(authed(CLIENT).doc("payments/order2").delete());
    await assertFails(authed(FREELANCER).doc("payments/order2").delete());
  });

  it("restricts payment.confirmed notices to the freelancer who was paid", async () => {
    await assertSucceeds(
      authed(FREELANCER)
        .collection(`users/${CLIENT}/notifications`)
        .add({
          type: "payment.confirmed",
          title: "Payment confirmed",
          body: "",
          read: false,
          orderId: "order2",
        })
    );
    // A buyer cannot fabricate their own confirmation receipt.
    await assertFails(
      authed(CLIENT)
        .collection(`users/${CLIENT}/notifications`)
        .add({
          type: "payment.confirmed",
          title: "fake",
          body: "",
          read: false,
          orderId: "order2",
        })
    );
  });
});

// Regression tests for defects that each broke a user-facing feature against
// deployed rules while passing analysis and unit tests.
describe("regressions", () => {
  it("lets a review be written without touching the order document", async () => {
    // The review flow used to stamp hasReview onto the order in the same
    // transaction. Orders accept status/deadline/updatedAt and nothing else,
    // so that write was denied and took every review down with it.
    const db = authed(CLIENT);
    const batch = db.batch();
    batch.set(db.doc("reviews/order1"), {
      orderId: "order1",
      serviceId: "service1",
      reviewerId: CLIENT,
      revieweeId: FREELANCER,
      rating: 5,
      comment: "Explained limits clearly.",
    });
    await assertSucceeds(batch.commit());

    // And the order still refuses a hasReview flag, so the repository must
    // keep deriving "reviewed?" from the review document's existence.
    await assertFails(
      authed(CLIENT).doc("orders/order1").update({ hasReview: true })
    );
  });

  it("reserves cancelling a pending request for the buyer", async () => {
    // The seller declines with `rejected`; the UI used to offer them a Cancel
    // button for a transition the rules have always denied.
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc("orders/order2").update({ status: "pending" });
    });
    await assertFails(
      authed(FREELANCER).doc("orders/order2").update({ status: "cancelled" })
    );
    await assertSucceeds(
      authed(CLIENT).doc("orders/order2").update({ status: "cancelled" })
    );
  });

  it("lets a conversation be reopened without re-stamping createdAt", async () => {
    const id = `${CLIENT}_${FREELANCER}`;
    const created = new Date("2026-01-01T00:00:00Z");
    await assertSucceeds(
      authed(CLIENT).doc(`conversations/${id}`).set({
        participantIds: [CLIENT, FREELANCER],
        lastMessagePreview: "",
        lastMessageSenderId: "",
        lastMessageAt: created,
        createdAt: created,
      })
    );
    // Re-opening must not move createdAt — the old merge wrote a fresh
    // serverTimestamp every time and was denied from the second open onward.
    await assertFails(
      authed(CLIENT)
        .doc(`conversations/${id}`)
        .set({ createdAt: new Date() }, { merge: true })
    );
    // Message metadata still updates freely.
    await assertSucceeds(
      authed(CLIENT)
        .doc(`conversations/${id}`)
        .update({ lastMessagePreview: "hello" })
    );
  });

  it("refuses a conversation created without createdAt", async () => {
    // Such a document could never be updated again, silently bricking a chat.
    await assertFails(
      authed(CLIENT).doc(`conversations/${CLIENT}_${STRANGER}`).set({
        participantIds: [CLIENT, STRANGER],
        lastMessagePreview: "",
        lastMessageSenderId: "",
      })
    );
  });

  it("bounds profile bio and skills, not just the display name", async () => {
    await assertFails(
      authed(CLIENT).doc(`users/${CLIENT}`).update({ bio: "x".repeat(501) })
    );
    await assertFails(
      authed(CLIENT)
        .doc(`users/${CLIENT}`)
        .update({ skills: Array.from({ length: 21 }, (_, i) => `s${i}`) })
    );
    await assertSucceeds(
      authed(CLIENT).doc(`users/${CLIENT}`).update({ bio: "Maths major." })
    );
  });

  it("rejects unlisted fields grafted onto a profile", async () => {
    await assertFails(
      authed(CLIENT).doc(`users/${CLIENT}`).update({ isAdmin: true })
    );
  });
});

describe("earnings queries", () => {
  beforeEach(async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc("payments/order2").set({
        orderId: "order2",
        clientId: CLIENT,
        freelancerId: FREELANCER,
        participantIds: [CLIENT, FREELANCER].sort(),
        amount: 500,
        currency: "PHP",
        commission: 25,
        netToFreelancer: 475,
        status: "paid",
        method: "manual",
        verified: false,
      });
    });
  });

  // For a list, Firestore proves a query safe only over the fields the query
  // constrains. The rule inspects participantIds, so a query that filters on
  // freelancerId alone leaves it unknown and is denied — which silently broke
  // every earnings read.
  it("allows a freelancer to total their own settled payments", async () => {
    const db = authed(FREELANCER);
    await assertSucceeds(
      db
        .collection("payments")
        .where("participantIds", "array-contains", FREELANCER)
        .where("freelancerId", "==", FREELANCER)
        .where("status", "==", "paid")
        .get()
    );
    await assertSucceeds(
      getCountFromServer(
        query(
          collection(db, "payments"),
          where("participantIds", "array-contains", FREELANCER),
          where("freelancerId", "==", FREELANCER),
          where("status", "==", "paid")
        )
      )
    );
  });

  // The transaction history page: every payment the student was party to,
  // newest first, and the Pro checkouts they own.
  it("lets a student list their own payment history, newest first", async () => {
    await assertSucceeds(
      authed(FREELANCER)
        .collection("payments")
        .where("participantIds", "array-contains", FREELANCER)
        .orderBy("updatedAt", "desc")
        .limit(100)
        .get()
    );
    await assertSucceeds(
      authed(FREELANCER)
        .collection("subscriptions")
        .where("uid", "==", FREELANCER)
        .orderBy("createdAt", "desc")
        .limit(50)
        .get()
    );
    await assertFails(
      authed(STRANGER)
        .collection("payments")
        .where("participantIds", "array-contains", FREELANCER)
        .orderBy("updatedAt", "desc")
        .get()
    );
  });

  it("denies a query that does not constrain participantIds", async () => {
    await assertFails(
      authed(FREELANCER)
        .collection("payments")
        .where("freelancerId", "==", FREELANCER)
        .get()
    );
  });

  it("stops a stranger totalling someone else's earnings", async () => {
    await assertFails(
      authed(STRANGER)
        .collection("payments")
        .where("participantIds", "array-contains", FREELANCER)
        .where("freelancerId", "==", FREELANCER)
        .where("status", "==", "paid")
        .get()
    );
  });
});

describe("rating counters", () => {
  // The reviewer bumps ratingSum/ratingCount in the same atomic write that
  // creates the review. The rule binds the two with getAfter(), so the
  // increment cannot disagree with the rating actually written.
  function reviewFor(orderId, rating) {
    return {
      orderId,
      serviceId: "service1",
      reviewerId: CLIENT,
      revieweeId: FREELANCER,
      rating,
      comment: "Clear, patient, and on time.",
    };
  }

  it("accepts a bump that matches the review in the same write", async () => {
    const db = authed(CLIENT);
    const batch = db.batch();
    batch.set(db.doc("reviews/order1"), reviewFor("order1", 4));
    batch.update(db.doc("services/service1"), {
      ratingSum: 4,
      ratingCount: 1,
      lastReviewId: "order1",
    });
    await assertSucceeds(batch.commit());
  });

  it("rejects a sum that does not match the rating written", async () => {
    const db = authed(CLIENT);
    const batch = db.batch();
    batch.set(db.doc("reviews/order1"), reviewFor("order1", 1));
    batch.update(db.doc("services/service1"), {
      ratingSum: 5,
      ratingCount: 1,
      lastReviewId: "order1",
    });
    await assertFails(batch.commit());
  });

  it("rejects a count that jumps by more than one", async () => {
    const db = authed(CLIENT);
    const batch = db.batch();
    batch.set(db.doc("reviews/order1"), reviewFor("order1", 5));
    batch.update(db.doc("services/service1"), {
      ratingSum: 5,
      ratingCount: 10,
      lastReviewId: "order1",
    });
    await assertFails(batch.commit());
  });

  it("rejects a bump with no review being created", async () => {
    await assertFails(
      authed(CLIENT).doc("services/service1").update({
        ratingSum: 5,
        ratingCount: 1,
        lastReviewId: "order1",
      })
    );
  });

  it("cannot be replayed off a review that already exists", async () => {
    // Land a legitimate review and bump first.
    const db = authed(CLIENT);
    const batch = db.batch();
    batch.set(db.doc("reviews/order1"), reviewFor("order1", 5));
    batch.update(db.doc("services/service1"), {
      ratingSum: 5,
      ratingCount: 1,
      lastReviewId: "order1",
    });
    await assertSucceeds(batch.commit());

    // Now try to bump again citing the same review. exists() is true this
    // time, so the write is refused — otherwise one review could be counted
    // over and over.
    await assertFails(
      db.doc("services/service1").update({
        ratingSum: 10,
        ratingCount: 2,
        lastReviewId: "order1",
      })
    );
  });

  it("rejects a bump citing someone else's review", async () => {
    const db = authed(STRANGER);
    const batch = db.batch();
    // The reviews rule itself blocks this, and so does the counter rule's
    // reviewerId check; both layers are exercised here.
    batch.set(db.doc("reviews/order1"), reviewFor("order1", 5));
    batch.update(db.doc("services/service1"), {
      ratingSum: 5,
      ratingCount: 1,
      lastReviewId: "order1",
    });
    await assertFails(batch.commit());
  });

  it("rejects a bump pointed at a different service", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc("services/service2").set({
        sellerId: FREELANCER,
        title: "Other",
        titleLower: "other",
        description: "Another listing entirely, twenty chars plus.",
        categoryId: "other",
        skills: [],
        startingPrice: 100,
        currency: "PHP",
        deliveryDays: 1,
        revisionCount: 0,
        status: "published",
        ratingSum: 0,
        ratingCount: 0,
      });
    });
    const db = authed(CLIENT);
    const batch = db.batch();
    batch.set(db.doc("reviews/order1"), reviewFor("order1", 5));
    // The review names service1, so service2 must not be able to claim it.
    batch.update(db.doc("services/service2"), {
      ratingSum: 5,
      ratingCount: 1,
      lastReviewId: "order1",
    });
    await assertFails(batch.commit());
  });

  it("stops a seller editing their own score", async () => {
    await assertFails(
      authed(FREELANCER).doc("services/service1").update({ ratingSum: 500, ratingCount: 100 })
    );
    // A normal edit still works.
    await assertSucceeds(
      authed(FREELANCER).doc("services/service1").update({
        title: "Tutoring, revised",
        titleLower: "tutoring, revised",
      })
    );
  });

  it("requires titleLower to match title", async () => {
    await assertFails(
      authed(FREELANCER).doc("services/service1").update({
        title: "Renamed",
        titleLower: "something else entirely",
      })
    );
  });
});

describe("staff access", () => {
  beforeEach(async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      // Only the Admin SDK can write this; clients cannot, which is the point.
      await ctx.firestore().doc(`admins/${ADMIN}`).set({ role: "admin", grantedAt: new Date() });
    });
  });

  it("cannot be granted from a client, by anyone", async () => {
    await assertFails(
      authed(STRANGER).doc(`admins/${STRANGER}`).set({ grantedAt: new Date() })
    );
    // Not even by an existing admin — the roster is Admin-SDK only.
    await assertFails(
      authed(ADMIN).doc("admins/someone-else").set({ grantedAt: new Date() })
    );
    await assertFails(authed(ADMIN).doc(`admins/${ADMIN}`).delete());
  });

  it("lets staff read across the marketplace, and nobody else", async () => {
    await assertSucceeds(authed(ADMIN).collection("orders").get());
    await assertSucceeds(authed(ADMIN).collection("payments").get());
    await assertSucceeds(authed(ADMIN).collection("users").get());
    await assertSucceeds(authed(ADMIN).collection("services").get());

    // A signed-in stranger still cannot enumerate any of it.
    await assertFails(authed(STRANGER).collection("orders").get());
    await assertFails(authed(STRANGER).collection("payments").get());
    await assertFails(authed(STRANGER).collection("users").get());
  });

  it("lets staff take a listing down but never rewrite it", async () => {
    await assertSucceeds(
      authed(ADMIN).doc("services/service1").update({ status: "paused" })
    );
    // Price, title and score are not theirs to touch.
    await assertFails(
      authed(ADMIN).doc("services/service1").update({ startingPrice: 1 })
    );
    await assertFails(
      authed(ADMIN).doc("services/service1").update({ ratingSum: 99, ratingCount: 9 })
    );
  });

  it("lets staff settle a disputed order, and only a disputed one", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc("orders/order2").update({ status: "disputed" });
    });
    await assertSucceeds(
      authed(ADMIN).doc("orders/order2").update({ status: "completed" })
    );

    // order1 is completed, not disputed: staff have no business reopening it.
    await assertFails(
      authed(ADMIN).doc("orders/order1").update({ status: "cancelled" })
    );
  });

  it("stops staff altering the money on an order they settle", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc("orders/order2").update({ status: "disputed" });
    });
    await assertFails(
      authed(ADMIN).doc("orders/order2").update({ status: "completed", price: 1 })
    );
  });

  it("keeps the audit trail append-only", async () => {
    const entry = {
      actorId: ADMIN,
      action: "service.paused",
      targetType: "service",
      targetId: "service1",
      note: "Reported by two buyers for undelivered work.",
      createdAt: new Date(),
    };
    await assertSucceeds(authed(ADMIN).collection("adminActions").add(entry));

    // Cannot be written in someone else's name, read by non-staff, or edited.
    await assertFails(
      authed(ADMIN).collection("adminActions").add({ ...entry, actorId: CLIENT })
    );
    await assertFails(authed(CLIENT).collection("adminActions").get());

    let existingId;
    await env.withSecurityRulesDisabled(async (ctx) => {
      const ref = ctx.firestore().collection("adminActions").doc();
      await ref.set(entry);
      existingId = ref.id;
    });
    await assertFails(
      authed(ADMIN).doc(`adminActions/${existingId}`).update({ note: "rewritten" })
    );
    await assertFails(authed(ADMIN).doc(`adminActions/${existingId}`).delete());
  });

  it("accepts a college from the closed list and rejects anything else", async () => {
    await assertSucceeds(
      authed(CLIENT).doc(`users/${CLIENT}`).update({
        collegeId: "cce",
        program: "BS Computer Science",
      })
    );
    await assertFails(
      authed(CLIENT).doc(`users/${CLIENT}`).update({ collegeId: "hogwarts" })
    );
    await assertFails(
      authed(CLIENT).doc(`users/${CLIENT}`).update({ program: "x".repeat(81) })
    );
  });
});


// ---------------------------------------------------------------------------
// Blaze features: attachments, push tokens, held money, Pro, verification.
//
// The pattern throughout: the client may write its own inputs, and nothing
// that the backend derives — balances, `proUntil`, `identityVerified`,
// `featuredUntil` — is reachable from any signed-in user.
// ---------------------------------------------------------------------------

describe("server-owned profile fields", () => {
  it("a student cannot grant themselves Pro or the verified badge", async () => {
    const me = authed(CLIENT).doc(`users/${CLIENT}`);
    await assertFails(me.update({ proUntil: new Date("2099-01-01") }));
    // The fixture profiles were seeded without the flag; a student cannot
    // flip it on later, only claim it at creation from a student address
    // (covered under "authentication boundary").
    await assertFails(me.update({ identityVerified: true }));
    await assertFails(
      authed(STRANGER).doc(`users/${STRANGER}`).set({
        uid: STRANGER,
        displayName: "Stranger",
        bio: "",
        skills: [],
        proUntil: new Date("2099-01-01"),
        createdAt: new Date(),
      })
    );
  });

  it("but a profile edit carries the backend's values through unchanged", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc(`users/${CLIENT}`).update({
        proUntil: new Date("2099-01-01T00:00:00Z"),
        identityVerified: true,
      });
    });
    await assertSucceeds(
      authed(CLIENT).doc(`users/${CLIENT}`).update({ bio: "hello" })
    );
    await assertFails(
      authed(CLIENT).doc(`users/${CLIENT}`).update({ identityVerified: false })
    );
  });
});

describe("push device tokens", () => {
  it("only the owner registers and reads their devices", async () => {
    const mine = authed(CLIENT).doc(`users/${CLIENT}/devices/tok1`);
    await assertSucceeds(
      mine.set({ token: "tok1", platform: "android", updatedAt: new Date() })
    );
    await assertSucceeds(mine.get());
    await assertFails(authed(STRANGER).doc(`users/${CLIENT}/devices/tok1`).get());
    await assertFails(
      authed(STRANGER)
        .doc(`users/${CLIENT}/devices/evil`)
        .set({ token: "evil", platform: "android", updatedAt: new Date() })
    );
  });

  it("rejects an unknown platform or extra fields", async () => {
    const mine = authed(CLIENT).doc(`users/${CLIENT}/devices/tok1`);
    await assertFails(
      mine.set({ token: "tok1", platform: "toaster", updatedAt: new Date() })
    );
    await assertFails(
      mine.set({ token: "tok1", platform: "web", admin: true })
    );
  });
});

describe("chat attachments", () => {
  beforeEach(async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc(`conversations/${CONVO_ID}`).set({
        participantIds: [CLIENT, FREELANCER],
        lastMessagePreview: "",
        lastMessageSenderId: "",
        createdAt: new Date("2026-01-01T00:00:00Z"),
      });
    });
  });

  const attachment = {
    attachmentUrl: "https://firebasestorage.googleapis.com/v0/b/demo.appspot.com/o/chat%2Fposter.png?alt=media",
    attachmentName: "poster.png",
    attachmentType: "image",
    attachmentSize: 120000,
  };

  for (const [type, limit] of [["image", 10], ["file", 10], ["video", 25]]) {
    it(`enforces the ${type} size boundary`, async () => {
      const messages = authed(CLIENT).collection(`conversations/${CONVO_ID}/messages`);
      const message = { senderId: CLIENT, text: "caption", ...attachment,
        attachmentType: type, attachmentSize: limit * 1024 * 1024 };
      await assertSucceeds(messages.add(message));
      await assertFails(messages.add({ ...message, attachmentSize: message.attachmentSize + 1 }));
      await assertFails(messages.add({ ...message, attachmentSize: 0 }));
      await assertFails(authed(STRANGER).collection(`conversations/${CONVO_ID}/messages`).add({ ...message, senderId: STRANGER }));
    });
  }

  it("allows cloud links as text but not as uploaded attachments", async () => {
    const messages = authed(CLIENT).collection(`conversations/${CONVO_ID}/messages`);
    const url = "https://drive.google.com/file/d/example/view";
    await assertSucceeds(messages.add({ senderId: CLIENT, text: url }));
    await assertFails(messages.add({ senderId: CLIENT, text: "", ...attachment, attachmentUrl: url }));
  });

  it("allows a file with no caption, but never a message with neither", async () => {
    const messages = authed(CLIENT).collection(`conversations/${CONVO_ID}/messages`);
    await assertSucceeds(messages.add({ senderId: CLIENT, text: "", ...attachment }));
    await assertSucceeds(messages.add({ senderId: CLIENT, text: "see attached", ...attachment }));
    await assertFails(messages.add({ senderId: CLIENT, text: "" }));
  });

  it("rejects a non-https url, an unknown type, or an oversized file", async () => {
    const messages = authed(CLIENT).collection(`conversations/${CONVO_ID}/messages`);
    await assertFails(
      messages.add({ senderId: CLIENT, text: "", ...attachment, attachmentUrl: "http://evil/x" })
    );
    await assertFails(
      messages.add({ senderId: CLIENT, text: "", ...attachment, attachmentType: "exe" })
    );
    await assertFails(
      messages.add({ senderId: CLIENT, text: "", ...attachment, attachmentSize: 11 * 1024 * 1024 })
    );
    await assertFails(
      messages.add({ senderId: CLIENT, text: "", ...attachment, extra: "field" })
    );
  });
});

describe("delivery attachments", () => {
  it("the freelancer may attach up to five files", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc("orders/order2").update({ status: "inProgress" });
    });
    const deliveries = authed(FREELANCER).collection("orders/order2/deliveries");
    const file = {
      url: "https://firebasestorage.googleapis.com/v0/b/demo.appspot.com/o/orders%2Ff.pdf?alt=media",
      name: "f.pdf",
      size: 10,
      type: "file",
    };
    await assertSucceeds(
      deliveries.add({ senderId: FREELANCER, note: "done", attachments: [file], createdAt: new Date() })
    );
    // A file that points anywhere but our Storage is a phishing link in a
    // delivery's clothes.
    await assertFails(
      deliveries.add({
        senderId: FREELANCER,
        note: "done",
        attachments: [file, { ...file, url: "https://evil.example/f.pdf" }],
        createdAt: new Date(),
      })
    );
    await assertFails(
      deliveries.add({
        senderId: FREELANCER,
        note: "done",
        attachments: [{ ...file, type: "exe" }],
        createdAt: new Date(),
      })
    );
    await assertFails(
      deliveries.add({
        senderId: FREELANCER,
        note: "done",
        attachments: Array(6).fill(file),
        createdAt: new Date(),
      })
    );
    await assertFails(
      authed(CLIENT).collection("orders/order2/deliveries").add({
        senderId: CLIENT,
        note: "done",
        attachments: [file],
        createdAt: new Date(),
      })
    );
  });
});

describe("featured listings", () => {
  const service = () => authed(FREELANCER).doc("services/service1");

  it("signed-in users can get a rotation projection but cannot list or write them", async () => {
    await assertSucceeds(authed(CLIENT).doc("featuredRotations/all__page_0").get());
    await assertFails(authed(CLIENT).collection("featuredRotations").get());
    await assertFails(
      authed(CLIENT).doc("featuredRotations/all__page_0").set({ serviceIds: ["forged"] })
    );
    await assertFails(unauthed().doc("featuredRotations/all__page_0").get());
  });

  it("a seller cannot feature their own listing", async () => {
    await assertFails(service().update({ featuredUntil: new Date("2099-01-01") }));
  });

  it("a seller's full save carries the backend's featuredUntil through", async () => {
    const until = new Date("2099-01-01T00:00:00Z");
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc("services/service1").update({ featuredUntil: until });
    });
    const snap = await service().get();
    const data = snap.data();
    // The app's save is a full overwrite (merge: false) of the same shape.
    await assertSucceeds(
      service().set({ ...data, title: "Tutoring (updated)", titleLower: "tutoring (updated)" })
    );
    await assertFails(service().set({ ...data, featuredUntil: null }));
  });
});

describe("wallets and money history", () => {
  const account = { type: "gcash", accountName: "Client", accountNumber: "09171234567" };

  it("the owner may set a payout account and nothing else", async () => {
    const wallet = authed(CLIENT).doc(`wallets/${CLIENT}`);
    await assertSucceeds(wallet.set({ uid: CLIENT, payoutAccount: account, updatedAt: new Date() }));
    await assertFails(
      authed(CLIENT).doc(`wallets/${STRANGER}`).set({ uid: STRANGER, payoutAccount: account })
    );
    await assertFails(wallet.update({ available: 1000000 }));
    await assertFails(wallet.update({ payoutAccount: { ...account, type: "crypto" } }));
    await assertSucceeds(
      wallet.update({ payoutAccount: { ...account, accountNumber: "09179999999" } })
    );
    // A number that cannot be a GCash account is refused before it can
    // become a mis-sent payout.
    await assertFails(
      wallet.update({ payoutAccount: { ...account, accountNumber: "0917999" } })
    );
    await assertFails(
      wallet.update({ payoutAccount: { ...account, accountNumber: "08179999999" } })
    );
    // A bank account must name its bank from the supported list.
    await assertFails(
      wallet.update({
        payoutAccount: { type: "bank", accountName: "Client", accountNumber: "123456789012" },
      })
    );
    await assertFails(
      wallet.update({
        payoutAccount: { type: "bank", accountName: "Client", accountNumber: "123456789012", bankCode: "PH_NOPE" },
      })
    );
    await assertSucceeds(
      wallet.update({
        payoutAccount: { type: "bank", accountName: "Client", accountNumber: "123456789012", bankCode: "PH_BDO" },
      })
    );
  });

  it("balances are visible to the owner and staff only", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      const db = ctx.firestore();
      await db.doc(`wallets/${FREELANCER}`).set({ uid: FREELANCER, available: 450 });
      await db.doc(`admins/${ADMIN}`).set({ role: "admin" });
      await db.collection("ledger").add({ uid: FREELANCER, type: "release", amount: 450, createdAt: new Date() });
      await db.collection("payouts").add({ uid: FREELANCER, amount: 450, status: "requested", requestedAt: new Date() });
      await db.doc("subscriptions/cs_1").set({ uid: FREELANCER, amount: 99, status: "paid" });
    });
    await assertSucceeds(authed(FREELANCER).doc(`wallets/${FREELANCER}`).get());
    await assertSucceeds(authed(ADMIN).doc(`wallets/${FREELANCER}`).get());
    await assertFails(authed(CLIENT).doc(`wallets/${FREELANCER}`).get());

    const mine = (col) =>
      authed(FREELANCER).collection(col).where("uid", "==", FREELANCER).get();
    const theirs = (col) =>
      authed(CLIENT).collection(col).where("uid", "==", FREELANCER).get();
    for (const col of ["ledger", "payouts", "subscriptions"]) {
      await assertSucceeds(mine(col));
      await assertFails(theirs(col));
      await assertSucceeds(authed(ADMIN).collection(col).get());
    }
  });

  it("nobody writes the ledger, payouts, or subscriptions from a client", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc(`admins/${ADMIN}`).set({ role: "admin" });
    });
    for (const who of [FREELANCER, ADMIN]) {
      await assertFails(
        authed(who).collection("ledger").add({ uid: who, type: "release", amount: 9999 })
      );
      await assertFails(
        authed(who).collection("payouts").add({ uid: who, amount: 9999, status: "paid" })
      );
      await assertFails(
        authed(who).doc("subscriptions/free").set({ uid: who, status: "paid" })
      );
    }
  });
});

describe("age gate", () => {
  const listing = (sellerId, status = "draft") => ({
    sellerId,
    title: "Tutoring",
    titleLower: "tutoring",
    description: "I will help you pass calculus exams.",
    categoryId: "tutoring",
    skills: [],
    startingPrice: 500,
    currency: "PHP",
    deliveryDays: 3,
    revisionCount: 1,
    status,
    ratingSum: 0,
    ratingCount: 0,
    createdAt: new Date(),
  });

  it("a minor, or a profile with no birth date, cannot create a listing", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      const db = ctx.firestore();
      await db.doc(`users/minor`).set({
        uid: "minor",
        displayName: "Minor",
        bio: "",
        skills: [],
        birthDate: new Date(Date.now() - 16 * 365 * 24 * 3600 * 1000),
        createdAt: new Date(),
      });
      await db.doc(`users/${STRANGER}`).set({
        uid: STRANGER,
        displayName: "No DOB",
        bio: "",
        skills: [],
        createdAt: new Date(),
      });
    });
    await assertFails(authed("minor").doc("services/m1").set(listing("minor")));
    await assertFails(authed(STRANGER).doc("services/s1").set(listing(STRANGER)));
    await assertSucceeds(authed(FREELANCER).doc("services/f1").set(listing(FREELANCER)));
  });

  it("a birth date is set once and cannot be moved afterwards", async () => {
    const me = authed(STRANGER).doc(`users/${STRANGER}`);
    await assertSucceeds(
      me.set({
        uid: STRANGER,
        displayName: "Stranger",
        bio: "",
        skills: [],
        createdAt: new Date(),
      })
    );
    // Adding one later is allowed (existing accounts predate the field)...
    await assertSucceeds(me.update({ birthDate: new Date("2000-01-01T00:00:00Z") }));
    // ...changing it is not, and an impossible date is refused outright.
    await assertFails(me.update({ birthDate: new Date("1990-01-01T00:00:00Z") }));
    await assertFails(
      authed(CLIENT).doc(`users/${CLIENT}`).update({ birthDate: new Date() })
    );
  });

  it("new profiles complete onboarding once and cannot grant themselves a staff label", async () => {
    const me = authed(STRANGER).doc(`users/${STRANGER}`);
    await assertSucceeds(me.set({
      uid: STRANGER,
      displayName: "Stranger",
      bio: "",
      skills: [],
      onboardingComplete: false,
      createdAt: new Date(),
    }));
    await assertSucceeds(me.update({
      collegeId: "cce",
      program: "BS Computer Science",
      onboardingComplete: true,
    }));
    await assertFails(me.update({ publicRole: "Admin" }));
    await assertFails(me.update({ onboardingComplete: false }));
  });

  it("a student may record accepting the payment terms", async () => {
    await assertSucceeds(
      authed(CLIENT).doc(`users/${CLIENT}`).update({ paymentTermsAcceptedAt: new Date() })
    );
    await assertFails(
      authed(CLIENT).doc(`users/${CLIENT}`).update({ paymentTermsAcceptedAt: "yes" })
    );
  });
});

describe("verification requests", () => {
  const request = (uid) => ({
    uid,
    schoolEmail: "maya@school.edu.ph",
    idImagePath: `verification/${uid}/id.jpg`,
    status: "pending",
    createdAt: new Date(),
  });

  it("a student submits their own, pending, pointing at their own folder", async () => {
    await assertSucceeds(
      authed(CLIENT).doc(`verificationRequests/${CLIENT}`).set(request(CLIENT))
    );
    await assertFails(
      authed(CLIENT).doc(`verificationRequests/${STRANGER}`).set(request(STRANGER))
    );
    await assertFails(
      authed(STRANGER)
        .doc(`verificationRequests/${STRANGER}`)
        .set({ ...request(STRANGER), status: "approved" })
    );
    await assertFails(
      authed(STRANGER)
        .doc(`verificationRequests/${STRANGER}`)
        .set({ ...request(STRANGER), idImagePath: `verification/${CLIENT}/id.jpg` })
    );
  });

  it("a pending request is not the student's to change; a rejected one is", async () => {
    const ref = authed(CLIENT).doc(`verificationRequests/${CLIENT}`);
    await assertSucceeds(ref.set(request(CLIENT)));
    await assertFails(ref.update({ schoolEmail: "other@school.edu.ph" }));
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc(`verificationRequests/${CLIENT}`).update({ status: "rejected" });
    });
    await assertSucceeds(
      ref.update({ schoolEmail: "other@school.edu.ph", status: "pending" })
    );
  });

  it("only staff see the queue", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      const db = ctx.firestore();
      await db.doc(`admins/${ADMIN}`).set({ role: "admin" });
      await db.doc(`verificationRequests/${CLIENT}`).set(request(CLIENT));
    });
    await assertSucceeds(authed(ADMIN).collection("verificationRequests").get());
    await assertSucceeds(authed(CLIENT).doc(`verificationRequests/${CLIENT}`).get());
    await assertFails(authed(STRANGER).doc(`verificationRequests/${CLIENT}`).get());
    await assertFails(authed(CLIENT).collection("verificationRequests").get());
  });
});


// ---------------------------------------------------------------------------
// Pricing modes and offers. A negotiable listing (or a fixed one whose
// seller asks to be contacted) cannot be ordered at the listed price; the
// order comes from an offer the client accepted, and carries the offer's
// figures. One offer, one order.
// ---------------------------------------------------------------------------

describe("pricing modes and offers", () => {
  const conversation = () => ({
    participantIds: [CLIENT, FREELANCER],
    lastMessagePreview: "",
    lastMessageSenderId: "",
    unreadCount: { [CLIENT]: 0, [FREELANCER]: 0 },
    createdAt: new Date("2026-01-01T00:00:00Z"),
  });

  const listing = (overrides = {}) => ({
    sellerId: FREELANCER,
    title: "Logo design",
    titleLower: "logo design",
    description: "A logo and a brand sheet for your org.",
    categoryId: "design",
    skills: [],
    startingPrice: 800,
    currency: "PHP",
    deliveryDays: 5,
    revisionCount: 2,
    status: "published",
    ratingSum: 0,
    ratingCount: 0,
    createdAt: new Date("2026-01-01T00:00:00Z"),
    ...overrides,
  });

  const directOrder = (serviceId, price) => ({
    serviceId,
    serviceTitle: "Logo design",
    clientId: CLIENT,
    freelancerId: FREELANCER,
    participantIds: [CLIENT, FREELANCER],
    price,
    currency: "PHP",
    deliveryDays: 5,
    revisionCount: 2,
    requirements: "A logo for the robotics club, blue and white.",
    status: "pending",
  });

  const offer = (serviceId, overrides = {}) => ({
    serviceId,
    serviceTitle: "Logo design",
    freelancerId: FREELANCER,
    clientId: CLIENT,
    participantIds: [CLIENT, FREELANCER],
    conversationId: CONVO_ID,
    price: 1200,
    currency: "PHP",
    deliveryDays: 7,
    revisionCount: 3,
    scope: "Primary logo, two variations, and a one-page brand sheet.",
    status: "pending",
    createdAt: new Date(),
    updatedAt: new Date(),
    expiresAt: new Date(Date.now() + 7 * 24 * 3600 * 1000),
    ...overrides,
  });

  beforeEach(async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      const db = ctx.firestore();
      await db.doc(`conversations/${CONVO_ID}`).set(conversation());
      await db.doc("services/fixed").set(listing());
      await db.doc("services/negotiable").set(listing({ pricingMode: "negotiable" }));
      await db.doc("services/contactFirst").set(listing({ requiresContact: true }));
    });
  });

  it("a fixed-price listing can be ordered directly at the listed price", async () => {
    await assertSucceeds(authed(CLIENT).doc("orders/d1").set(directOrder("fixed", 800)));
    await assertFails(authed(CLIENT).doc("orders/d2").set(directOrder("fixed", 700)));
  });

  it("negotiable and contact-first listings cannot be ordered directly at all", async () => {
    await assertFails(authed(CLIENT).doc("orders/n1").set(directOrder("negotiable", 800)));
    await assertFails(authed(CLIENT).doc("orders/c1").set(directOrder("contactFirst", 800)));
  });

  it("only the seller of a published listing may send an offer, to the other participant", async () => {
    await assertSucceeds(authed(FREELANCER).doc("offers/o1").set(offer("negotiable")));
    await assertFails(authed(CLIENT).doc("offers/o2").set(offer("negotiable", { freelancerId: CLIENT, clientId: FREELANCER })));
    await assertFails(authed(STRANGER).doc("offers/o3").set(offer("negotiable", { freelancerId: STRANGER })));
    await assertFails(authed(FREELANCER).doc("offers/o4").set(offer("negotiable", { clientId: STRANGER })));
    await assertFails(authed(FREELANCER).doc("offers/o5").set(offer("negotiable", { price: 0 })));
    await assertFails(authed(FREELANCER).doc("offers/o6").set(offer("negotiable", { status: "accepted" })));
    await assertFails(authed(FREELANCER).doc("offers/o7").set(offer("negotiable", { serviceTitle: "Something else" })));
  });

  it("the offer card is a message that names an offer created in the same batch", async () => {
    const db = authed(FREELANCER);
    const batch = db.batch();
    batch.set(db.doc("offers/o1"), offer("negotiable"));
    batch.set(db.doc(`conversations/${CONVO_ID}/messages/m1`), {
      senderId: FREELANCER,
      text: "",
      offerId: "o1",
      sentAt: new Date(),
    });
    await assertSucceeds(batch.commit());

    // A message pointing at an offer that does not exist, or someone else's.
    await assertFails(
      db.collection(`conversations/${CONVO_ID}/messages`).add({
        senderId: FREELANCER,
        text: "",
        offerId: "ghost",
        sentAt: new Date(),
      })
    );
  });

  it("the client answers a pending offer; the freelancer may only withdraw", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc("offers/o1").set(offer("negotiable"));
    });
    await assertFails(authed(FREELANCER).doc("offers/o1").update({ status: "accepted" }));
    await assertFails(authed(CLIENT).doc("offers/o1").update({ status: "withdrawn" }));
    await assertFails(authed(CLIENT).doc("offers/o1").update({ status: "accepted", price: 1 }));
    await assertFails(authed(STRANGER).doc("offers/o1").update({ status: "accepted" }));
    await assertSucceeds(authed(CLIENT).doc("offers/o1").update({ status: "accepted" }));
    // Decided is decided.
    await assertFails(authed(CLIENT).doc("offers/o1").update({ status: "declined" }));
  });

  it("an expired offer can be declined but no longer accepted", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      const db = ctx.firestore();
      const stale = offer("negotiable", { expiresAt: new Date(Date.now() - 60 * 1000) });
      await db.doc("offers/o_old").set(stale);
      await db.doc("offers/o_old2").set(stale);
    });
    await assertFails(authed(CLIENT).doc("offers/o_old").update({ status: "accepted" }));
    await assertSucceeds(authed(CLIENT).doc("offers/o_old2").update({ status: "declined" }));
  });

  it("an accepted offer becomes exactly one order, at the offer's price", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc("offers/o1").set(offer("negotiable", { status: "accepted" }));
    });
    const db = authed(CLIENT);
    const fromOffer = (overrides = {}) => ({
      ...directOrder("negotiable", 1200),
      deliveryDays: 7,
      revisionCount: 3,
      scope: "Primary logo, two variations, and a one-page brand sheet.",
      offerId: "o1",
      ...overrides,
    });

    // Wrong price, or the offer not marked ordered in the same batch.
    const wrongPrice = db.batch();
    wrongPrice.set(db.doc("orders/x1"), fromOffer({ price: 800 }));
    wrongPrice.update(db.doc("offers/o1"), { status: "ordered", orderId: "x1" });
    await assertFails(wrongPrice.commit());
    await assertFails(db.doc("orders/x2").set(fromOffer()));

    const good = db.batch();
    good.set(db.doc("orders/ok"), fromOffer());
    good.update(db.doc("offers/o1"), { status: "ordered", orderId: "ok" });
    await assertSucceeds(good.commit());

    // The same offer cannot be spent again.
    const again = db.batch();
    again.set(db.doc("orders/dup"), fromOffer());
    again.update(db.doc("offers/o1"), { status: "ordered", orderId: "dup" });
    await assertFails(again.commit());
  });

  it("an offer cannot be marked ordered without an order that names it", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc("offers/o1").set(offer("negotiable", { status: "accepted" }));
    });
    await assertFails(authed(CLIENT).doc("offers/o1").update({ status: "ordered", orderId: "nothing" }));
  });

  it("a suspended student cannot order, offer, or message", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc(`users/${CLIENT}`).update({ suspended: true });
    });
    await assertFails(authed(CLIENT).doc("orders/s1").set(directOrder("fixed", 800)));
    await assertFails(
      authed(CLIENT).collection(`conversations/${CONVO_ID}/messages`).add({
        senderId: CLIENT,
        text: "hello",
        sentAt: new Date(),
      })
    );
    // Reading still works: a suspended account is not a deleted one.
    await assertSucceeds(authed(CLIENT).doc("services/fixed").get());
    // And nobody can un-suspend themselves.
    await assertFails(authed(CLIENT).doc(`users/${CLIENT}`).update({ suspended: false }));
  });

  it("a suspended seller cannot republish a listing or move an order forward", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      const db = ctx.firestore();
      await db.doc(`users/${FREELANCER}`).update({ suspended: true });
      await db.doc("services/fixed").update({ status: "paused" });
      await db.doc("orders/susp1").set({
        ...directOrder("fixed", 800),
        clientId: CLIENT,
        freelancerId: FREELANCER,
        participantIds: [CLIENT, FREELANCER].sort(),
        status: "pending",
      });
    });
    await assertFails(authed(FREELANCER).doc("services/fixed").update({ status: "published" }));
    await assertFails(authed(FREELANCER).doc("orders/susp1").update({ status: "accepted" }));
    // Declining is a way out, not a sale.
    await assertSucceeds(authed(FREELANCER).doc("orders/susp1").update({ status: "rejected" }));
  });
});


// ---------------------------------------------------------------------------
// Role-based staff access. The main admin (role 'admin', service-account
// written) can do everything; staff hold a permission list and each surface
// asks for exactly one. Nobody grants themselves anything.
// ---------------------------------------------------------------------------

describe("staff roles and permissions", () => {
  const STAFF = "staff-uid";

  const seedStaff = (permissions) =>
    env.withSecurityRulesDisabled(async (ctx) => {
      const db = ctx.firestore();
      await db.doc(`admins/${ADMIN}`).set({ role: "admin" });
      await db.doc(`admins/${STAFF}`).set({ role: "staff", permissions });
      await db.doc("orders/disputed").set({
        serviceId: "service1",
        serviceTitle: "Tutoring",
        clientId: CLIENT,
        freelancerId: FREELANCER,
        participantIds: [CLIENT, FREELANCER],
        price: 500,
        currency: "PHP",
        deliveryDays: 3,
        revisionCount: 1,
        requirements: "Please help me with derivatives and limits.",
        status: "disputed",
      });
      await db.doc("payments/disputed").set({
        orderId: "disputed",
        clientId: CLIENT,
        freelancerId: FREELANCER,
        participantIds: [CLIENT, FREELANCER],
        amount: 500,
        currency: "PHP",
        commission: 25,
        netToFreelancer: 475,
        status: "paid",
        method: "xendit",
        verified: true,
      });
    });

  it("a moderator can take down a listing and inspect sellers, but cannot suspend them", async () => {
    await seedStaff(["services.moderate"]);
    const me = authed(STAFF);
    await assertSucceeds(me.collection("services").get());
    await assertSucceeds(me.doc("services/service1").update({ status: "paused" }));
    await assertFails(me.collection("orders").get());
    await assertFails(me.doc("orders/disputed").update({ status: "completed" }));
    await assertSucceeds(me.collection("users").get());
    await assertFails(me.doc(`users/${CLIENT}`).update({ suspended: true }));
    await assertFails(me.collection("wallets").get());
    await assertFails(me.collection("auditLog").get());
  });

  it("a dispute handler can close disputes but cannot moderate listings", async () => {
    await seedStaff(["disputes.resolve"]);
    const me = authed(STAFF);
    await assertSucceeds(me.collection("orders").get());
    await assertSucceeds(me.doc("payments/disputed").get());
    await assertSucceeds(me.doc("orders/disputed").update({ status: "completed" }));
    await assertFails(me.doc("services/service1").update({ status: "paused" }));
  });

  it("a user manager can suspend and reinstate, and only that", async () => {
    await seedStaff(["users.manage"]);
    const me = authed(STAFF);
    await assertSucceeds(me.collection("users").get());
    await assertSucceeds(me.doc(`users/${CLIENT}`).update({ suspended: true }));
    await assertSucceeds(me.doc(`users/${CLIENT}`).update({ suspended: false }));
    await assertFails(me.doc(`users/${CLIENT}`).update({ displayName: "Renamed" }));
    await assertFails(me.doc(`users/${CLIENT}`).update({ proUntil: new Date("2099-01-01") }));
  });

  // A dispute at or above the second-opinion threshold (2000 pesos, twinned
  // in functions/policy.js and DisputePolicy) needs two different staff.
  const BIG = {
    serviceId: "service1",
    serviceTitle: "Thesis formatting",
    clientId: CLIENT,
    freelancerId: FREELANCER,
    participantIds: [CLIENT, FREELANCER],
    price: 5000,
    currency: "PHP",
    deliveryDays: 5,
    revisionCount: 2,
    requirements: "Format a 120-page thesis to the university template.",
    status: "disputed",
  };
  const SECOND = "second-staff-uid";
  const seedBigDispute = () =>
    env.withSecurityRulesDisabled(async (ctx) => {
      const db = ctx.firestore();
      await db.doc("orders/big").set(BIG);
      await db.doc(`admins/${SECOND}`).set({ role: "staff", permissions: ["disputes.resolve"] });
    });
  const propose = (uid, outcome, extra = {}) =>
    authed(uid).doc("orders/big").update({
      disputeResolution: { outcome, proposedBy: uid, proposedAt: serverTimestamp() },
      updatedAt: serverTimestamp(),
      ...extra,
    });

  it("a large dispute cannot be closed by one staff member alone", async () => {
    await seedStaff(["disputes.resolve"]);
    await seedBigDispute();
    await assertFails(authed(STAFF).doc("orders/big").update({ status: "completed" }));
    await assertFails(authed(STAFF).doc("orders/big").update({ status: "cancelled" }));
    // Not even the main admin.
    await assertFails(authed(ADMIN).doc("orders/big").update({ status: "completed" }));
    // The same person still closes a small one on their own.
    await assertSucceeds(authed(STAFF).doc("orders/disputed").update({ status: "completed" }));
  });

  it("a proposal names its author, moves nothing else, and cannot be confirmed by its author", async () => {
    await seedStaff(["disputes.resolve"]);
    await seedBigDispute();
    // Someone else's name on it, a made-up outcome, or a status change riding
    // along are all refused.
    await assertFails(
      authed(STAFF).doc("orders/big").update({
        disputeResolution: { outcome: "completed", proposedBy: SECOND, proposedAt: serverTimestamp() },
      })
    );
    await assertFails(propose(STAFF, "refunded"));
    await assertFails(propose(STAFF, "completed", { status: "completed" }));

    await assertSucceeds(propose(STAFF, "completed"));
    await assertFails(
      authed(STAFF).doc("orders/big").update({ status: "completed" }),
      "the proposer cannot confirm their own proposal"
    );
    // A participant cannot forge a proposal either.
    await assertFails(propose(CLIENT, "cancelled"));
  });

  it("a second staff member confirms exactly the proposed outcome", async () => {
    await seedStaff(["disputes.resolve"]);
    await seedBigDispute();
    await assertSucceeds(propose(STAFF, "cancelled"));
    await assertFails(
      authed(SECOND).doc("orders/big").update({ status: "completed" }),
      "confirming a different outcome is a new decision, not a confirmation"
    );
    // The second staff member may propose the other outcome instead, which
    // replaces the first proposal and sends it back to the first.
    await assertSucceeds(propose(SECOND, "completed"));
    await assertFails(authed(SECOND).doc("orders/big").update({ status: "completed" }));
    await assertSucceeds(authed(STAFF).doc("orders/big").update({ status: "completed" }));
  });

  it("the main admin holds every permission without a list", async () => {
    await seedStaff([]);
    const boss = authed(ADMIN);
    await assertSucceeds(boss.collection("users").get());
    await assertSucceeds(boss.collection("orders").get());
    await assertSucceeds(boss.collection("wallets").get());
    await assertSucceeds(boss.collection("auditLog").get());
    await assertSucceeds(boss.doc("services/service1").update({ status: "paused" }));
  });

  it("staff with no permissions can read nothing staff-only", async () => {
    await seedStaff([]);
    const me = authed(STAFF);
    await assertFails(me.collection("orders").get());
    await assertFails(me.collection("services").get());
    await assertFails(me.collection("payouts").get());
    await assertSucceeds(me.doc(`admins/${STAFF}`).get(), "may read their own access");
    await assertFails(me.collection("admins").get());
  });

  it("only the main admin grants staff, never a main admin, never themselves", async () => {
    await seedStaff(["users.manage"]);
    const boss = authed(ADMIN);
    await assertSucceeds(
      boss.doc(`admins/${STRANGER}`).set({
        role: "staff",
        permissions: ["services.moderate", "reports.view"],
        createdBy: ADMIN,
        createdAt: new Date(),
      })
    );
    await assertFails(
      boss.doc(`admins/${CLIENT}`).set({ role: "admin", permissions: [], createdBy: ADMIN })
    );
    await assertFails(
      boss.doc(`admins/${CLIENT}`).set({ role: "staff", permissions: ["everything"], createdBy: ADMIN })
    );
    await assertFails(boss.doc(`admins/${ADMIN}`).update({ permissions: [] }));
    await assertSucceeds(boss.doc(`admins/${STRANGER}`).delete());
    await assertFails(boss.doc(`admins/${ADMIN}`).delete());

    // Staff cannot grant, extend, or read the roster.
    const staff = authed(STAFF);
    await assertFails(
      staff.doc(`admins/${CLIENT}`).set({ role: "staff", permissions: ["users.manage"], createdBy: STAFF })
    );
    await assertFails(staff.doc(`admins/${STAFF}`).update({ permissions: ["users.manage", "payouts.settle"] }));
    await assertFails(staff.collection("admins").get());
  });

  it("categories and settings are staff-managed and readable by everyone", async () => {
    await seedStaff(["categories.manage"]);
    const me = authed(STAFF);
    await assertSucceeds(
      me.doc("categories/3d-printing").set({ label: "3D printing", active: true, sortOrder: 9, updatedAt: new Date() })
    );
    await assertFails(
      me.doc("categories/Bad Id").set({ label: "x", active: true, sortOrder: 1 })
    );
    await assertFails(me.doc("categories/3d-printing").delete());
    await assertSucceeds(authed(CLIENT).collection("categories").get());
    await assertFails(authed(CLIENT).doc("categories/hack").set({ label: "hack", active: true, sortOrder: 1 }));

    await assertFails(me.doc("settings/platform").set({ ordersPaused: true }));
    await assertSucceeds(
      authed(ADMIN).doc("settings/platform").set({ announcement: "Enrollment week: slower replies.", ordersPaused: false })
    );
    await assertSucceeds(
      authed(ADMIN).doc("settings/platform").set({
        announcement: "Enrollment week: slower replies.",
        announcementExpiresAt: new Date(Date.now() + 3600_000),
        ordersPaused: false,
      })
    );
    await assertFails(
      authed(ADMIN).doc("settings/platform").set({
        announcement: "Invalid expiry",
        announcementExpiresAt: "tomorrow",
        ordersPaused: false,
      })
    );
    await assertSucceeds(authed(CLIENT).doc("settings/platform").get());
  });

  it("pausing orders platform-wide stops new orders, not reads", async () => {
    await seedStaff([]);
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc("settings/platform").set({ ordersPaused: true });
    });
    await assertFails(
      authed(CLIENT).doc("orders/paused").set({
        serviceId: "service1",
        serviceTitle: "Tutoring",
        clientId: CLIENT,
        freelancerId: FREELANCER,
        participantIds: [CLIENT, FREELANCER],
        price: 500,
        currency: "PHP",
        deliveryDays: 3,
        revisionCount: 1,
        requirements: "Please help me with derivatives and limits.",
        status: "pending",
      })
    );
    await assertSucceeds(authed(CLIENT).doc("orders/order1").get());
  });

  it("the audit log is read by reporters and written by nobody", async () => {
    await seedStaff(["reports.view"]);
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().collection("auditLog").add({ action: "order.created", createdAt: new Date() });
    });
    await assertSucceeds(authed(STAFF).collection("auditLog").get());
    await assertFails(authed(CLIENT).collection("auditLog").get());
    await assertFails(authed(ADMIN).collection("auditLog").add({ action: "forged" }));
  });
});


// ---------------------------------------------------------------------------
// The exact write sequence the app performs to open a conversation and send
// a message, with the real FieldValue sentinels. A rule that passes a
// hand-shaped fixture but refuses what ChatRepository actually writes is the
// kind of bug only this catches.
// ---------------------------------------------------------------------------

describe("chat, as the app writes it", () => {
  const { serverTimestamp, increment } = require("firebase/firestore");

  async function openConversation(db, me, other) {
    const id = [me, other].sort().join("_");
    await db.runTransaction(async (tx) => {
      const ref = db.doc(`conversations/${id}`);
      const snap = await tx.get(ref);
      if (snap.exists) return;
      tx.set(ref, {
        participantIds: [me, other].sort(),
        unreadCount: { [me]: 0, [other]: 0 },
        lastMessagePreview: "",
        lastMessageSenderId: "",
        lastMessageAt: serverTimestamp(),
        createdAt: serverTimestamp(),
      });
    });
    return id;
  }

  function sendText(db, conversationId, me, other, text) {
    const batch = db.batch();
    batch.set(db.collection(`conversations/${conversationId}/messages`).doc(), {
      senderId: me,
      text,
      sentAt: serverTimestamp(),
    });
    batch.update(db.doc(`conversations/${conversationId}`), {
      lastMessagePreview: text,
      lastMessageSenderId: me,
      lastMessageAt: serverTimestamp(),
      [`unreadCount.${other}`]: increment(1),
      [`unreadCount.${me}`]: 0,
    });
    batch.set(db.collection(`users/${other}/notifications`).doc(), {
      type: "chat.message",
      title: "New message",
      body: "",
      read: false,
      conversationId,
      createdAt: serverTimestamp(),
      expiresAt: new Date(Date.now() + 60 * 24 * 3600 * 1000),
    });
    return batch.commit();
  }

  it("a student opens a conversation from a listing and sends the first message", async () => {
    const me = authed(CLIENT);
    const id = await openConversation(me, CLIENT, FREELANCER);
    await assertSucceeds(sendText(me, id, CLIENT, FREELANCER, "hi, is this still available?"));
    // Reopening (the seller tapping Message on the buyer's profile) is a no-op
    // that must not be refused.
    await assertSucceeds(openConversation(authed(FREELANCER), FREELANCER, CLIENT));
    await assertSucceeds(sendText(authed(FREELANCER), id, FREELANCER, CLIENT, "yes!"));
    // Opening the thread clears my own counter.
    await assertSucceeds(me.doc(`conversations/${id}`).update({ [`unreadCount.${CLIENT}`]: 0 }));
    await assertSucceeds(me.collection(`conversations/${id}/messages`).get());
    await assertSucceeds(me.collection("conversations").where("participantIds", "array-contains", CLIENT).get());
  });

  it("a student whose profile document is missing can still message", async () => {
    // A profile write can fail after sign-in (offline, a rules mismatch on a
    // Google account's name); the conversation must not be the thing that
    // then breaks, because that is where the student goes to ask for help.
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc(`users/${CLIENT}`).delete();
    });
    const me = authed(CLIENT);
    const id = await openConversation(me, CLIENT, FREELANCER);
    await assertSucceeds(sendText(me, id, CLIENT, FREELANCER, "hello?"));
  });
});
