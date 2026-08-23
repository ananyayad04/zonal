// Data models mirroring the API payloads.

enum Role { resident, student, worker, officer, admin, unknown }

/// Roles that file complaints and sign the work off. Identical in what they
/// can do; separate in who sees what they file.
const reporterRoles = {Role.resident, Role.student};

Role roleFrom(String? v) => switch (v) {
      'RESIDENT' => Role.resident,
      'STUDENT' => Role.student,
      'WORKER' => Role.worker,
      'OFFICER' => Role.officer,
      'ADMIN' => Role.admin,
      _ => Role.unknown,
    };

class Zone {
  final String id;
  final int code;
  final String name;
  final String label;
  final String colorHex;
  final List<List<double>> polygon;
  final double? centroidLat;
  final double? centroidLng;

  const Zone({
    required this.id,
    required this.code,
    required this.name,
    required this.label,
    required this.colorHex,
    this.polygon = const [],
    this.centroidLat,
    this.centroidLng,
  });

  factory Zone.fromJson(Map<String, dynamic> j) {
    final poly = (j['polygon'] as List?)
            ?.map<List<double>>(
              (p) => (p as List).map((n) => (n as num).toDouble()).toList(),
            )
            .toList() ??
        const <List<double>>[];

    final centroid = j['centroid'] as Map<String, dynamic>?;

    return Zone(
      id: j['id'] as String,
      code: j['code'] as int,
      name: j['name'] as String,
      label: j['label'] as String? ?? '',
      colorHex: j['colorHex'] as String? ?? '#4F86C6',
      polygon: poly,
      centroidLat: (centroid?['lat'] as num?)?.toDouble(),
      centroidLng: (centroid?['lng'] as num?)?.toDouble(),
    );
  }
}

class WorkerInfo {
  final String zoneId;
  final Zone? zone;
  final String approvalStatus; // PENDING | ACTIVE | REJECTED
  final String? rejectionNote;
  final String dutyStatus; // ON | OFF
  final String availability; // AVAILABLE | BUSY
  final int activeTaskCount;
  final int tasksCompletedToday;
  final int tasksCompletedTotal;

  const WorkerInfo({
    required this.zoneId,
    this.zone,
    required this.approvalStatus,
    this.rejectionNote,
    required this.dutyStatus,
    required this.availability,
    required this.activeTaskCount,
    required this.tasksCompletedToday,
    required this.tasksCompletedTotal,
  });

  bool get isApproved => approvalStatus == 'ACTIVE';
  bool get isOnDuty => dutyStatus == 'ON';

  factory WorkerInfo.fromJson(Map<String, dynamic> j) => WorkerInfo(
        zoneId: j['zoneId'] as String? ?? '',
        zone: j['zone'] != null ? Zone.fromJson(j['zone'] as Map<String, dynamic>) : null,
        approvalStatus: j['approvalStatus'] as String? ?? 'PENDING',
        rejectionNote: j['rejectionNote'] as String?,
        dutyStatus: j['dutyStatus'] as String? ?? 'OFF',
        availability: j['availability'] as String? ?? 'AVAILABLE',
        activeTaskCount: j['activeTaskCount'] as int? ?? 0,
        tasksCompletedToday: j['tasksCompletedToday'] as int? ?? 0,
        tasksCompletedTotal: j['tasksCompletedTotal'] as int? ?? 0,
      );
}

/// An officer's application to run a zone.
///
/// Present from the moment they sign up, which is how the app knows to show a
/// "waiting for verification" screen instead of an officer dashboard with
/// nothing in it. [AppUser.zone] stays null until an admin approves.
class OfficerInfo {
  final Zone? zone;
  final String approvalStatus; // PENDING | ACTIVE | REJECTED
  final String? rejectionNote;

  const OfficerInfo({this.zone, required this.approvalStatus, this.rejectionNote});

  bool get isApproved => approvalStatus == 'ACTIVE';
  bool get isRejected => approvalStatus == 'REJECTED';

  factory OfficerInfo.fromJson(Map<String, dynamic> j) => OfficerInfo(
        zone: j['zone'] != null ? Zone.fromJson(j['zone'] as Map<String, dynamic>) : null,
        approvalStatus: j['approvalStatus'] as String? ?? 'PENDING',
        rejectionNote: j['rejectionNote'] as String?,
      );
}

class AppUser {
  final String id;
  final String name;
  final String email;
  final String? phone;
  final Role role;
  final WorkerInfo? worker;
  final OfficerInfo? officer;
  final Zone? zone; // the zone an officer actually holds; null until approved

  const AppUser({
    required this.id,
    required this.name,
    required this.email,
    this.phone,
    required this.role,
    this.worker,
    this.officer,
    this.zone,
  });

  /// True when this account has signed up but an admin has not cleared it yet.
  bool get awaitingVerification =>
      (role == Role.worker && worker != null && !worker!.isApproved) ||
      (role == Role.officer && officer != null && !officer!.isApproved);

  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser(
        id: j['id'] as String,
        name: j['name'] as String,
        email: j['email'] as String,
        phone: j['phone'] as String?,
        role: roleFrom(j['role'] as String?),
        worker: j['worker'] != null
            ? WorkerInfo.fromJson(j['worker'] as Map<String, dynamic>)
            : null,
        officer: j['officer'] != null
            ? OfficerInfo.fromJson(j['officer'] as Map<String, dynamic>)
            : null,
        zone: j['zone'] != null ? Zone.fromJson(j['zone'] as Map<String, dynamic>) : null,
      );
}

/// A named place on campus — a department, hostel, gate or facility.
class Landmark {
  final String id;
  final String name;
  final int? zoneCode;

  const Landmark({required this.id, required this.name, this.zoneCode});

  factory Landmark.fromJson(Map<String, dynamic> j) => Landmark(
        id: j['id'] as String,
        name: j['name'] as String,
        zoneCode: j['zoneCode'] as int?,
      );
}

/// Landmarks under a heading, so a list of twenty-odd places stays readable.
class LandmarkGroup {
  final String category;
  final String label;
  final List<Landmark> landmarks;

  const LandmarkGroup({
    required this.category,
    required this.label,
    required this.landmarks,
  });

  factory LandmarkGroup.fromJson(Map<String, dynamic> j) => LandmarkGroup(
        category: j['category'] as String,
        label: j['label'] as String,
        landmarks: (j['landmarks'] as List)
            .map((l) => Landmark.fromJson(l as Map<String, dynamic>))
            .toList(),
      );
}

class MediaItem {
  final String id;
  final String url;
  final String type; // PHOTO | VIDEO | AUDIO
  final String phase; // BEFORE | AFTER
  final int? durationSec;

  const MediaItem({
    required this.id,
    required this.url,
    required this.type,
    required this.phase,
    this.durationSec,
  });

  factory MediaItem.fromJson(Map<String, dynamic> j) => MediaItem(
        id: j['id'] as String,
        url: j['url'] as String,
        type: j['type'] as String,
        phase: j['phase'] as String,
        durationSec: j['durationSec'] as int?,
      );
}

class PersonRef {
  final String id;
  final String name;
  final String? phone;

  const PersonRef({required this.id, required this.name, this.phone});

  factory PersonRef.fromJson(Map<String, dynamic> j) => PersonRef(
        id: j['id'] as String,
        name: j['name'] as String,
        phone: j['phone'] as String?,
      );
}

class Complaint {
  final String id;
  final String ref;
  final String category;
  final String? description;
  final String status;
  final String priority;

  /// Emergency reports skip admin verification and are broadcast to every
  /// officer and on-duty worker at once.
  final bool isEmergency;

  final double lat;
  final double lng;

  /// Where a worker should actually walk to. The zone says which part of
  /// campus; this says which building.
  final String? landmark;
  final String? landmarkNote;

  /// This place was signed off only days ago and is dirty again.
  final bool isRecurrence;
  final int? recurrenceDays;

  final Zone? zone;

  /// How the zone was decided: POLYGON, NEAREST_EDGE, OVERLAP_SMALLEST,
  /// OUT_OF_BOUNDS, RESIDENT_OVERRIDE or ADMIN_OVERRIDE.
  final String? zoneResolvedBy;
  final double? zoneDistanceM;

  /// True when the GPS fix did not land cleanly inside one boundary, so the
  /// admin should confirm the zone before it is routed to an officer.
  final bool isBoundaryCase;

  final PersonRef? reporter;
  final PersonRef? officer;
  final PersonRef? worker;

  final bool isCrossZone;
  final Zone? lendingZone;

  final List<MediaItem> beforeMedia;
  final List<MediaItem> afterMedia;

  /// Which community filed this — RESIDENT or STUDENT. Staff screens show it
  /// so a student report can be told from a resident one at a glance.
  final Role reporterRole;

  final String satisfaction;
  /// What the reporter said when they signed the work off.
  final String? feedbackNote;
  final String? unsatisfiedNote;
  final int reopenCount;
  final String? rejectionReason;
  final String? escalationReason;

  final DateTime? submittedAt;
  final DateTime? doneAt;
  final DateTime? closedAt;
  final DateTime? slaDueAt;
  final bool isOverdue;
  final int? resolutionMinutes;

  const Complaint({
    required this.id,
    required this.ref,
    required this.category,
    this.description,
    required this.status,
    required this.priority,
    this.isEmergency = false,
    required this.lat,
    required this.lng,
    this.landmark,
    this.landmarkNote,
    this.isRecurrence = false,
    this.recurrenceDays,
    this.zone,
    this.zoneResolvedBy,
    this.zoneDistanceM,
    this.isBoundaryCase = false,
    this.reporter,
    this.reporterRole = Role.resident,
    this.feedbackNote,
    this.officer,
    this.worker,
    required this.isCrossZone,
    this.lendingZone,
    this.beforeMedia = const [],
    this.afterMedia = const [],
    required this.satisfaction,
    this.unsatisfiedNote,
    required this.reopenCount,
    this.rejectionReason,
    this.escalationReason,
    this.submittedAt,
    this.doneAt,
    this.closedAt,
    this.slaDueAt,
    required this.isOverdue,
    this.resolutionMinutes,
  });

  static DateTime? _date(dynamic v) => v == null ? null : DateTime.tryParse(v as String)?.toLocal();

  factory Complaint.fromJson(Map<String, dynamic> j) {
    final loc = j['location'] as Map<String, dynamic>? ?? const {};
    final ts = j['timestamps'] as Map<String, dynamic>? ?? const {};

    List<MediaItem> media(String key) =>
        (j[key] as List?)?.map((m) => MediaItem.fromJson(m as Map<String, dynamic>)).toList() ??
        const [];

    return Complaint(
      id: j['id'] as String,
      ref: j['ref'] as String,
      category: j['category'] as String,
      description: j['description'] as String?,
      status: j['status'] as String,
      priority: j['priority'] as String? ?? 'MEDIUM',
      isEmergency: j['isEmergency'] as bool? ?? false,
      lat: (loc['lat'] as num?)?.toDouble() ?? 0,
      lng: (loc['lng'] as num?)?.toDouble() ?? 0,
      landmark: j['landmark'] as String?,
      landmarkNote: j['landmarkNote'] as String?,
      isRecurrence: j['isRecurrence'] as bool? ?? false,
      recurrenceDays: j['recurrenceDays'] as int?,
      zone: j['zone'] != null ? Zone.fromJson(j['zone'] as Map<String, dynamic>) : null,
      zoneResolvedBy: j['zoneResolvedBy'] as String?,
      zoneDistanceM: (j['zoneDistanceM'] as num?)?.toDouble(),
      isBoundaryCase: j['isBoundaryCase'] as bool? ?? false,
      reporterRole: roleFrom(j['reporterRole'] as String?),
      feedbackNote: j['feedbackNote'] as String?,
      reporter: j['reporter'] != null
          ? PersonRef.fromJson(j['reporter'] as Map<String, dynamic>)
          : null,
      officer:
          j['officer'] != null ? PersonRef.fromJson(j['officer'] as Map<String, dynamic>) : null,
      worker: j['worker'] != null ? PersonRef.fromJson(j['worker'] as Map<String, dynamic>) : null,
      isCrossZone: j['isCrossZone'] as bool? ?? false,
      lendingZone: j['lendingZone'] != null
          ? Zone.fromJson(j['lendingZone'] as Map<String, dynamic>)
          : null,
      beforeMedia: media('beforeMedia'),
      afterMedia: media('afterMedia'),
      satisfaction: j['satisfaction'] as String? ?? 'PENDING',
      unsatisfiedNote: j['unsatisfiedNote'] as String?,
      reopenCount: j['reopenCount'] as int? ?? 0,
      rejectionReason: j['rejectionReason'] as String?,
      escalationReason: j['escalationReason'] as String?,
      submittedAt: _date(ts['submittedAt']),
      doneAt: _date(ts['doneAt']),
      closedAt: _date(ts['closedAt']),
      slaDueAt: _date(j['slaDueAt']),
      isOverdue: j['isOverdue'] as bool? ?? false,
      resolutionMinutes: j['resolutionMinutes'] as int?,
    );
  }
}

class TimelineEntry {
  final String? from;
  final String to;
  final String? actorName;
  final String? actorRole;
  final bool isSystem;
  final String? note;
  final DateTime at;

  const TimelineEntry({
    this.from,
    required this.to,
    this.actorName,
    this.actorRole,
    required this.isSystem,
    this.note,
    required this.at,
  });

  factory TimelineEntry.fromJson(Map<String, dynamic> j) {
    final actor = j['actor'] as Map<String, dynamic>?;
    return TimelineEntry(
      from: j['from'] as String?,
      to: j['to'] as String,
      actorName: actor?['name'] as String?,
      actorRole: actor?['role'] as String?,
      isSystem: j['isSystem'] as bool? ?? false,
      note: j['note'] as String?,
      at: DateTime.parse(j['at'] as String).toLocal(),
    );
  }
}

class FreeWorker {
  final String userId;
  final String name;
  final String? phone;
  final int tasksCompletedToday;

  const FreeWorker({
    required this.userId,
    required this.name,
    this.phone,
    required this.tasksCompletedToday,
  });

  factory FreeWorker.fromJson(Map<String, dynamic> j) => FreeWorker(
        userId: j['userId'] as String,
        name: j['name'] as String,
        phone: j['phone'] as String?,
        tasksCompletedToday: j['tasksCompletedToday'] as int? ?? 0,
      );
}

class AppNotification {
  final String id;
  final String title;
  final String body;
  final String? complaintId;
  final DateTime createdAt;
  final bool read;

  const AppNotification({
    required this.id,
    required this.title,
    required this.body,
    this.complaintId,
    required this.createdAt,
    required this.read,
  });

  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
        id: j['id'] as String,
        title: j['title'] as String,
        body: j['body'] as String,
        complaintId: j['complaintId'] as String?,
        createdAt: DateTime.parse(j['createdAt'] as String).toLocal(),
        read: j['readAt'] != null,
      );
}
