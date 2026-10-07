import 'package:cloud_firestore/cloud_firestore.dart';

/// What a staff member may do. Mirrors `knownPermissions()` in
/// `firestore.rules` and `PERMISSIONS` in `functions/policy.js`; the rules
/// and the backend enforce these, the app only decides what to show.
enum AdminPermission {
  usersManage(
    'users.manage',
    'Manage students',
    'List, search, suspend and reinstate accounts',
  ),
  servicesModerate(
    'services.moderate',
    'Moderate listings',
    'See every listing and take one down',
  ),
  categoriesManage(
    'categories.manage',
    'Manage categories',
    'Add, rename, reorder and retire categories',
  ),
  ordersManage(
    'orders.manage',
    'Manage orders',
    'See every order, offer and transaction',
  ),
  disputesResolve(
    'disputes.resolve',
    'Resolve disputes',
    'Close a disputed order as released or refunded',
  ),
  payoutsSettle(
    'payouts.settle',
    'Settle payouts',
    'Record transfers and return payouts',
  ),
  refundsHandle(
    'refunds.handle',
    'Handle refunds',
    'Retry or record refunds the gateway refused',
  ),
  verificationDecide(
    'verification.decide',
    'Decide verifications',
    'Approve or reject student-ID checks',
  ),
  reportsView(
    'reports.view',
    'View reports',
    'Platform figures, money held and the audit log',
  ),
  settingsManage(
    'settings.manage',
    'Platform settings',
    'Announcement banner and the order pause',
  );

  const AdminPermission(this.wireName, this.label, this.description);

  final String wireName;
  final String label;
  final String description;

  static AdminPermission? fromWire(String? name) {
    for (final p in AdminPermission.values) {
      if (p.wireName == name) return p;
    }
    return null;
  }
}

enum AdminRole {
  /// The main admin: every permission, written only by a service-account key.
  admin,

  /// Granted specific permissions by the main admin.
  staff;

  static AdminRole fromName(String? name) =>
      name == 'admin' ? AdminRole.admin : AdminRole.staff;
}

/// One `admins/{uid}` document: who this staff member is and what they may do.
class AdminAccess {
  const AdminAccess({
    required this.uid,
    required this.role,
    required this.permissions,
    this.displayName,
    this.email,
    this.createdAt,
  });

  final String uid;
  final AdminRole role;
  final Set<AdminPermission> permissions;
  final String? displayName;
  final String? email;
  final DateTime? createdAt;

  bool get isMainAdmin => role == AdminRole.admin;

  bool can(AdminPermission permission) =>
      isMainAdmin || permissions.contains(permission);

  /// The main admin also manages staff; that is not a grantable permission.
  bool get canManageStaff => isMainAdmin;

  factory AdminAccess.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data() ?? const {};
    return AdminAccess(
      uid: doc.id,
      role: AdminRole.fromName(data['role'] as String?),
      permissions: {
        for (final name in data['permissions'] as List<dynamic>? ?? const [])
          ?AdminPermission.fromWire(name as String?),
      },
      displayName: data['displayName'] as String?,
      email: data['email'] as String?,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}

/// One line of the platform's audit log, written only by the backend.
class AuditEntry {
  const AuditEntry({
    required this.id,
    required this.actorId,
    required this.action,
    required this.createdAt,
    this.targetType,
    this.targetId,
    this.details = const {},
  });

  final String id;
  final String actorId;
  final String action;
  final DateTime createdAt;
  final String? targetType;
  final String? targetId;
  final Map<String, dynamic> details;

  /// "Order status changed", "Payout settled": the action id read aloud.
  String get label {
    final parts = action.split('.');
    if (parts.length != 2) return action;
    final subject = parts[0][0].toUpperCase() + parts[0].substring(1);
    return '$subject ${parts[1].replaceAll('_', ' ')}';
  }

  factory AuditEntry.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return AuditEntry(
      id: doc.id,
      actorId: data['actorId'] as String? ?? 'system',
      action: data['action'] as String? ?? '',
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      targetType: data['targetType'] as String?,
      targetId: data['targetId'] as String?,
      details: (data['details'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }
}

/// A human-readable subject for an audit entry. The immutable audit record
/// deliberately stores stable document ids; this is the separately resolved
/// display label staff see in the console.
class AuditSubject {
  const AuditSubject({required this.label, this.kind});

  final String label;
  final String? kind;
}

/// A marketplace category, staff-managed. The app merges these over its
/// built-in list, so a listing's `categoryId` always has a label.
class Category {
  const Category({
    required this.id,
    required this.label,
    required this.active,
    required this.sortOrder,
  });

  final String id;
  final String label;
  final bool active;
  final int sortOrder;

  factory Category.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return Category(
      id: doc.id,
      label: data['label'] as String? ?? doc.id,
      active: data['active'] as bool? ?? true,
      sortOrder: (data['sortOrder'] as num?)?.toInt() ?? 0,
    );
  }
}

/// The switches staff may flip at runtime, at `settings/platform`.
class PlatformSettings {
  const PlatformSettings({
    this.announcement = '',
    this.ordersPaused = false,
    this.announcementExpiresAt,
  });

  static const none = PlatformSettings();

  /// Shown as a banner across the app while non-empty.
  final String announcement;

  /// New orders are refused (in rules too) while true; existing ones move.
  final bool ordersPaused;

  final DateTime? announcementExpiresAt;

  bool get hasActiveAnnouncement =>
      announcement.isNotEmpty &&
      (announcementExpiresAt == null ||
          announcementExpiresAt!.isAfter(DateTime.now()));

  factory PlatformSettings.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data() ?? const {};
    return PlatformSettings(
      announcement: data['announcement'] as String? ?? '',
      ordersPaused: data['ordersPaused'] as bool? ?? false,
      announcementExpiresAt: (data['announcementExpiresAt'] as Timestamp?)
          ?.toDate(),
    );
  }
}
