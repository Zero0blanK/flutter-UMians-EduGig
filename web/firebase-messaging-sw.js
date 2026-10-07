/* eslint-disable no-undef */
// Web push service worker. firebase_messaging looks for this exact file name
// at the site root; without it getToken() fails and the web build simply has
// no push (the in-app inbox still works).
//
// The config below is the public web app config from lib/firebase_options.dart
// — the same values every visitor already receives in the JS bundle. Nothing
// secret lives here.
importScripts('https://www.gstatic.com/firebasejs/10.14.1/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.14.1/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey: 'AIzaSyDbF37RHXqjBvkcemXema7VBUgIv6yqjsk',
  appId: '1:933240164340:web:09429198ce30e95b1773a1',
  messagingSenderId: '933240164340',
  projectId: 'student-freelance-services',
  authDomain: 'student-freelance-services.firebaseapp.com',
  storageBucket: 'student-freelance-services.firebasestorage.app',
});

// Background messages with a `notification` block are shown by the browser
// on their own; this handler exists so the SDK registers the worker.
firebase.messaging().onBackgroundMessage(() => {});
