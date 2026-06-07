import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/errors/failures.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/error_widget.dart';
import '../../domain/entities/course.dart';
import '../../domain/entities/lesson.dart';
import '../../domain/entities/review.dart';
import '../providers/courses_provider.dart';
import '../providers/di_providers.dart';
import '../providers/profile_provider.dart';

class CourseDetailScreen extends ConsumerStatefulWidget {
  final int courseId;
  const CourseDetailScreen({super.key, required this.courseId});

  @override
  ConsumerState<CourseDetailScreen> createState() => _CourseDetailScreenState();
}

class _CourseDetailScreenState extends ConsumerState<CourseDetailScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  bool _enrolling = false;

  // FIX: local state بسيط بدون أي provider magic
  // يُحدَّث فوراً بعد التسجيل ويبقى حتى يُغلق المستخدم الشاشة أو يُؤكد الـ server
  bool _enrolledLocally = false;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  // الـ enrollment الفعلي = server value OR local override
  bool _effectiveEnrolled(Course course) => course.isEnrolled || _enrolledLocally;

  Future<void> _enroll(Course course) async {
    setState(() => _enrolling = true);

    final result = await ref.read(enrollCourseUseCaseProvider).call(course.id);
    if (!mounted) return;

    setState(() => _enrolling = false);

    result.fold(
      (f) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(f.message),
          backgroundColor: Theme.of(context).colorScheme.error,
        ));
      },
      (_) {
        // FIX: حدّث الـ UI فوراً عبر local state — لا race conditions
        setState(() => _enrolledLocally = true);

        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
            'تم التسجيل بنجاح! ',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
        ));

        // FIX: أعد تحميل بعد 800ms — يُعطي الـ DB وقتاً للاستقرار
        // لا نستدعي invalidate فوراً لأن الـ backend قد يُعيد is_enrolled: false
        // بسبب الـ cache أو latency
        Future.delayed(const Duration(milliseconds: 800), () {
          if (!mounted) return;
          // امسح الـ cache المحلي أولاً
          ref.read(courseRepositoryProvider); // warm provider
          // أعد تحميل الـ topics (الآن الـ server يُعيد البيانات بشكل صحيح)
          ref.invalidate(topicsProvider(widget.courseId));
          // أعد تحميل الكورس من الـ server للمزامنة (skipLoadingOnRefresh يحميه من الوميض)
          ref.invalidate(courseDetailProvider(widget.courseId));
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final courseAsync = ref.watch(courseDetailProvider(widget.courseId));

    return courseAsync.when(
      // FIX: لا تُظهر loading أثناء refresh — يحمي من وميض الـ UI
      skipLoadingOnRefresh: true,
      skipLoadingOnReload:  true,
      loading: () => Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(),
        body: AppErrorWidget(
          message: e.toString().replaceAll('Exception: ', ''),
          onRetry: () => ref.invalidate(courseDetailProvider(widget.courseId)),
        ),
      ),
      data: (course) {
        // FIX: لما يُؤكد الـ server التسجيل — نُزيل الـ local flag
        // لأن course.isEnrolled أصبح true من الـ server مباشرة
        if (course.isEnrolled && _enrolledLocally) {
          // ScheduleMicrotask لتجنب setState أثناء build
          Future.microtask(() {
            if (mounted) setState(() => _enrolledLocally = false);
          });
        }
        return _buildScaffold(course);
      },
    );
  }

  Widget _buildScaffold(Course course) {
    final theme    = Theme.of(context);
    final enrolled = _effectiveEnrolled(course);

    return Scaffold(
      body: NestedScrollView(
        headerSliverBuilder: (_, __) => [
          SliverAppBar(
            expandedHeight: 220,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              background: course.thumbnail.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: course.thumbnail,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) =>
                          Container(color: theme.colorScheme.primaryContainer),
                    )
                  : Container(color: theme.colorScheme.primaryContainer),
            ),
            title: Text(course.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16)),
          ),
          SliverToBoxAdapter(child: _courseHeader(course, theme)),
          SliverPersistentHeader(
            pinned: true,
            delegate: _TabBarDelegate(
              TabBar(
                controller: _tabCtrl,
                tabs: const [
                  Tab(text: 'عن الدورة'),
                  Tab(text: 'المحتوى'),
                  Tab(text: 'التقييمات'),
                ],
              ),
            ),
          ),
        ],
        body: TabBarView(
          controller: _tabCtrl,
          children: [
            _AboutTab(course: course),
            _ContentTab(courseId: course.id, isEnrolled: enrolled),
            _ReviewsTab(courseId: course.id),
          ],
        ),
      ),
      bottomNavigationBar: _buildBottomBar(course, theme, enrolled),
    );
  }

  Widget _courseHeader(Course course, ThemeData theme) {
    return Container(
      color: theme.colorScheme.surface,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ✅ النص الأساسي: onSurface + weight 800
          Text(
            course.title,
            style: theme.textTheme.titleLarge?.copyWith(
              color: theme.colorScheme.onSurface,
              fontWeight: FontWeight.w800,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 14),
          // Stats chips
          Wrap(spacing: 8, runSpacing: 8, children: [
            _InfoChip(
              icon: Icons.star_rounded,
              label: '${course.rating.toStringAsFixed(1)} (${course.ratingCount})',
              color: const Color(0xFFF59E0B),
            ),
            _InfoChip(
              icon: Icons.people_rounded,
              label: '${course.totalEnrolled} طالب',
              color: const Color(0xFF3B82F6),
            ),
            _InfoChip(
              icon: Icons.menu_book_rounded,
              label: '${course.totalLessons} درس',
              color: const Color(0xFF10B981),
            ),
            if (course.isFree)
              _InfoChip(
                icon: Icons.card_giftcard_rounded,
                label: 'مجاني',
                color: const Color(0xFF10B981),
                filled: true,
              ),
          ]),
          const SizedBox(height: 14),
          // Instructor card
          GestureDetector(
            onTap: () => context.push('/instructor/${course.instructorId}'),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Row(children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: const Color(0xFFFFE4E5),
                  backgroundImage: course.instructorAvatar.isNotEmpty
                      ? CachedNetworkImageProvider(course.instructorAvatar)
                      : null,
                  child: course.instructorAvatar.isEmpty
                      ? const Icon(Icons.person_rounded, size: 20, color: AppTheme.brandRed)
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ✅ النص الأساسي: onSurface + weight 700
                      Text(
                        course.instructorName,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      // ✅ النص الثانوي: onSurfaceVariant
                      Text(
                        'المحاضر',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.arrow_back_ios_rounded, size: 14, color: theme.colorScheme.onSurfaceVariant),
              ]),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  // ✅ تحسين 2 و 3 و 4: Bottom Bar مع Material surface وتأثيرات نظيفة
  Widget _buildBottomBar(Course course, ThemeData theme, bool enrolled) {
    return enrolled
        ? Material(
            color: theme.colorScheme.surface,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                child: SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton.icon(
                    onPressed: () => context.push('/lessons/${course.id}'),
                    icon: const Icon(Icons.play_arrow_rounded, size: 20),
                    label: const Text(
                      'ابدأ التعلم الآن',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(52),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      elevation: 0, // ✅ إلغاء elevation لأن داخل bottom bar
                    ),
                  ),
                ),
              ),
            ),
          )
        : Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              border: Border(
                top: BorderSide(
                  color: theme.colorScheme.outlineVariant,
                  width: 1,
                ),
              ),
            ),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                child: Row(children: [
                  if (!course.isFree) ...[
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // ✅ النص الثانوي: onSurfaceVariant
                        Text(
                          'السعر',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          course.price,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w900,
                            color: AppTheme.brandRed,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 16),
                  ],
                  Expanded(
                    child: SizedBox(
                      height: 52,
                      child: FilledButton(
                        onPressed: _enrolling ? null : () => _enroll(course),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppTheme.brandRed,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                        child: _enrolling
                            ? const SizedBox(height: 20, width: 20,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : Text(
                                course.isFree ? 'التسجيل مجاناً 🎓' : 'التسجيل الآن',
                                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                              ),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
          );
  }
}

// ── Tab: About ────────────────────────────────────────────────────────────────

class _AboutTab extends StatelessWidget {
  final Course course;
  const _AboutTab({required this.course});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Html(
        data: course.description.isNotEmpty
            ? course.description
            : '<p>لا يوجد وصف متاح</p>',
      ),
    );
  }
}

// ── Tab: Content ──────────────────────────────────────────────────────────────

class _ContentTab extends ConsumerWidget {
  final int courseId;
  final bool isEnrolled;

  const _ContentTab({required this.courseId, required this.isEnrolled});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final topicsAsync = ref.watch(topicsProvider(courseId));
    final theme = Theme.of(context);

    return topicsAsync.when(
      skipLoadingOnRefresh: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) {
        if (e is EnrollmentFailure && isEnrolled) {
          return const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('جارٍ تحميل المحتوى...'),
              ],
            ),
          );
        }
        if (e is EnrollmentFailure) {
          return _EnrollmentPlaceholder(onGoToEnroll: () {
            DefaultTabController.maybeOf(context)?.animateTo(0);
          });
        }
        return AppErrorWidget(
          message: e.toString().replaceAll('Exception: ', ''),
          onRetry: () => ref.invalidate(topicsProvider(courseId)),
        );
      },
      data: (topics) {
        if (topics.isEmpty) {
          return Center(
            child: Text(
              'لا يوجد محتوى بعد',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: topics.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (_, i) {
            final topic = topics[i];
            return Card(
              margin: EdgeInsets.zero,
              child: ExpansionTile(
                initiallyExpanded: i == 0,
                title: Text(
                  topic.title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                subtitle: Text(
                  '${topic.lessons.length} درس',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                children: topic.lessons
                    .map((lesson) => _LessonTile(
                          lesson:     lesson,
                          courseId:   courseId,
                          isEnrolled: isEnrolled,
                          allLessons: topic.lessons,
                        ))
                    .toList(),
              ),
            );
          },
        );
      },
    );
  }
}

// ── Enrollment placeholder ────────────────────────────────────────────────────

class _EnrollmentPlaceholder extends StatelessWidget {
  final VoidCallback onGoToEnroll;
  const _EnrollmentPlaceholder({required this.onGoToEnroll});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lock_outline_rounded,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'سجّل في الدورة لعرض المحتوى',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 20),
            OutlinedButton(
              onPressed: onGoToEnroll,
              child: const Text('اذهب للتسجيل'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Lesson Tile ───────────────────────────────────────────────────────────────

class _LessonTile extends StatelessWidget {
  final Lesson lesson;
  final int courseId;
  final bool isEnrolled;
  final List<Lesson> allLessons;

  const _LessonTile({
    required this.lesson,
    required this.courseId,
    required this.isEnrolled,
    required this.allLessons,
  });

  void _onTap(BuildContext context) {
    if (!isEnrolled) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('سجّل في الدورة للوصول إلى هذا المحتوى'),
        action: SnackBarAction(
          label: 'التسجيل',
          onPressed: () =>
              DefaultTabController.maybeOf(context)?.animateTo(0),
        ),
      ));
      return;
    }

    if (lesson.isVideo) {
      context.push('/video/${lesson.id}', extra: {
        'lesson'    : lesson,
        'courseId'  : courseId,
        'allLessons': allLessons,
      });
    } else if (lesson.isQuiz) {
      context.push('/quiz/${lesson.id}');
    } else if (lesson.isAssignment) {
      context.push('/lesson-web/${lesson.id}', extra: {'title': lesson.title});
    } else {
      context.push('/lesson-web/${lesson.id}', extra: {'title': lesson.title});
    }
  }

  IconData get _icon {
    if (lesson.isCompleted)   return Icons.check_rounded;
    if (!isEnrolled)          return Icons.lock_outline_rounded;
    if (lesson.isQuiz)        return Icons.quiz_rounded;
    if (lesson.isAssignment)  return Icons.assignment_rounded;
    if (lesson.isVideo)       return Icons.play_arrow_rounded;
    return Icons.article_outlined;
  }

  Color _iconColor(ThemeData t) {
    if (lesson.isCompleted)  return Colors.green;
    if (!isEnrolled)         return t.colorScheme.onSurfaceVariant;
    if (lesson.isQuiz)       return t.colorScheme.secondary;
    if (lesson.isAssignment) return t.colorScheme.tertiary;
    return t.colorScheme.primary;
  }

  Color _bgColor(ThemeData t) {
    if (lesson.isCompleted)  return Colors.green.withValues(alpha: 0.12);
    if (!isEnrolled)         return t.colorScheme.surfaceContainerHighest;
    if (lesson.isQuiz)       return t.colorScheme.secondaryContainer;
    if (lesson.isAssignment) return t.colorScheme.tertiaryContainer;
    return t.colorScheme.primaryContainer;
  }

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final locked = !isEnrolled;

    return ListTile(
      onTap: () => _onTap(context),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      leading: Container(
        width: 36, height: 36,
        decoration: BoxDecoration(shape: BoxShape.circle, color: _bgColor(theme)),
        child: Icon(_icon, size: 18, color: _iconColor(theme)),
      ),
      title: Text(
        lesson.title,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w500,
          color: locked
              ? theme.colorScheme.onSurfaceVariant
              : theme.colorScheme.onSurface,
          decoration: lesson.isCompleted ? TextDecoration.lineThrough : null,
        ),
      ),
      subtitle: _buildSubtitle(theme),
      trailing: locked
          ? null
          : Icon(Icons.chevron_left_rounded, color: theme.colorScheme.onSurfaceVariant),
    );
  }

  Widget? _buildSubtitle(ThemeData theme) {
    final isSpecial = lesson.isQuiz || lesson.isAssignment;
    final duration  = lesson.videoDuration;
    if (!isSpecial && duration.isEmpty) return null;

    return Wrap(spacing: 6, children: [
      if (isSpecial)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: lesson.isQuiz
                ? theme.colorScheme.secondaryContainer
                : theme.colorScheme.tertiaryContainer,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            lesson.isQuiz ? 'اختبار' : 'واجب',
            style: theme.textTheme.labelSmall?.copyWith(
              color: lesson.isQuiz
                  ? theme.colorScheme.secondary
                  : theme.colorScheme.tertiary,
            ),
          ),
        ),
      if (duration.isNotEmpty)
        Text(
          duration,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
    ]);
  }
}

// ── Tab: Reviews ──────────────────────────────────────────────────────────────

class _ReviewsTab extends ConsumerWidget {
  final int courseId;
  const _ReviewsTab({required this.courseId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reviewsAsync = ref.watch(reviewsProvider(courseId));
    final theme = Theme.of(context);

    return reviewsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => AppErrorWidget(
          message: e.toString().replaceAll('Exception: ', '')),
      data: (reviews) {
        if (reviews.isEmpty) {
          return Center(
            child: Text(
              'لا توجد تقييمات بعد',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: reviews.length,
          separatorBuilder: (_, __) => const Divider(),
          itemBuilder: (_, i) => _ReviewTile(review: reviews[i]),
        );
      },
    );
  }
}

class _ReviewTile extends StatelessWidget {
  final Review review;
  const _ReviewTile({required this.review});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            backgroundImage: review.authorAvatar.isNotEmpty
                ? CachedNetworkImageProvider(review.authorAvatar)
                : null,
            child: review.authorAvatar.isEmpty
                ? Text(review.authorName.isNotEmpty ? review.authorName[0] : '?')
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  // ✅ اسم المراجع: onSurface + bold
                  Text(
                    review.authorName,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const Spacer(),
                  Row(
                    children: List.generate(
                      5,
                      (i) => Icon(
                        Icons.star_rounded,
                        size: 14,
                        color: i < review.rating.round()
                            ? Colors.amber
                            : theme.colorScheme.surfaceContainerHighest,
                      ),
                    ),
                  ),
                ]),
                const SizedBox(height: 4),
                // ✅ ✅ تصحيح: النص الثانوي يجب أن يكون onSurfaceVariant (ليس onSurface)
                Text(
                  review.content,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Persistent TabBar ─────────────────────────────────────────────────────────

// ── Info Chip ─────────────────────────────────────────────────────────────────

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final bool filled;
  const _InfoChip({required this.icon, required this.label, required this.color, this.filled = false});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: filled ? color : color.withValues(alpha: 0.09),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: filled ? Colors.white : color),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700).copyWith(
              color: filled ? Colors.white : color,
            ),
          ),
        ]),
      );
}

class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  final TabBar tabBar;
  const _TabBarDelegate(this.tabBar);

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) =>
      Material(color: Theme.of(context).scaffoldBackgroundColor, child: tabBar);

  @override
  double get maxExtent => tabBar.preferredSize.height;
  @override
  double get minExtent => tabBar.preferredSize.height;
  @override
  bool shouldRebuild(_TabBarDelegate old) => false;
}
