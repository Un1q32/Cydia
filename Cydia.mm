/* #include Directives {{{ */
#include <Foundation/NSURL.h>
#include <UIKit/UIKit.h>
#import <GraphicsServices/GraphicsServices.h>

#include <sstream>
#include <ext/stdio_filebuf.h>

#include <apt-pkg/acquire.h>
#include <apt-pkg/acquire-item.h>
#include <apt-pkg/algorithms.h>
#include <apt-pkg/cachefile.h>
#include <apt-pkg/configuration.h>
#include <apt-pkg/debmetaindex.h>
#include <apt-pkg/error.h>
#include <apt-pkg/init.h>
#include <apt-pkg/pkgrecords.h>
#include <apt-pkg/sourcelist.h>
#include <apt-pkg/sptr.h>

#include <sys/sysctl.h>

#include <errno.h>
#include <pcre.h>
#include <string.h>
/* }}} */
/* Extension Keywords {{{ */
#define _trace() fprintf(stderr, "_trace()@%s:%u[%s]\n", __FILE__, __LINE__, __FUNCTION__)

#define _assert(test) do \
    if (!(test)) { \
        fprintf(stderr, "_assert(%d:%s)@%s:%u[%s]\n", errno, #test, __FILE__, __LINE__, __FUNCTION__); \
        exit(-1); \
    } \
while (false)
/* }}} */

@interface WebView
- (void) setApplicationNameForUserAgent:(NSString *)applicationName;
@end

static const int PulseInterval_ = 50000;
const char *Machine_ = NULL;
const char *SerialNumber_ = NULL;

@interface NSString (CydiaBypass)
- (NSString *) stringByAddingPercentEscapes;
@end

@protocol ProgressDelegate
- (void) setError:(NSString *)error;
- (void) setTitle:(NSString *)title;
- (void) setPercent:(float)percent;
- (void) addOutput:(NSString *)output;
@end

NSString *SizeString(double size) {
    unsigned power = 0;
    while (size > 1024) {
        size /= 1024;
        ++power;
    }

    static const char *powers_[] = {"B", "kB", "MB", "GB"};

    return [NSString stringWithFormat:@"%.1f%s", size, powers_[power]];
}

/* Status Delegation {{{ */
class Status :
    public pkgAcquireStatus
{
  private:
    id delegate_;

  public:
    Status() :
        delegate_(nil)
    {
    }

    void setDelegate(id delegate) {
        delegate_ = delegate;
    }

    virtual bool MediaChange(std::string media, std::string drive) {
        return false;
    }

    virtual void IMSHit(pkgAcquire::ItemDesc &item) {
    }

    virtual void Fetch(pkgAcquire::ItemDesc &item) {
        [delegate_ setTitle:[NSString stringWithCString:("Downloading " + item.ShortDesc).c_str()]];
    }

    virtual void Done(pkgAcquire::ItemDesc &item) {
    }

    virtual void Fail(pkgAcquire::ItemDesc &item) {
        [delegate_ performSelectorOnMainThread:@selector(setStatusFail) withObject:nil waitUntilDone:YES];
    }

    virtual bool Pulse(pkgAcquire *Owner) {
        bool value = pkgAcquireStatus::Pulse(Owner);

        float percent(
            double(CurrentBytes + CurrentItems) /
            double(TotalBytes + TotalItems)
        );

        [delegate_ setPercent:percent];
        return value;
    }

    virtual void Start() {
    }

    virtual void Stop() {
    }
};
/* }}} */
/* Progress Delegation {{{ */
class Progress :
    public OpProgress
{
  private:
    id delegate_;

  protected:
    virtual void Update() {
        [delegate_ setTitle:[NSString stringWithCString:Op.c_str()]];
        [delegate_ setPercent:(Percent / 100)];
    }

  public:
    Progress() :
        delegate_(nil)
    {
    }

    void setDelegate(id delegate) {
        delegate_ = delegate;
    }

    virtual void Done() {
        [delegate_ setPercent:1];
    }
};
/* }}} */

/* External Constants {{{ */
extern NSString *kUIButtonBarButtonAction;
extern NSString *kUIButtonBarButtonInfo;
extern NSString *kUIButtonBarButtonInfoOffset;
extern NSString *kUIButtonBarButtonSelectedInfo;
extern NSString *kUIButtonBarButtonStyle;
extern NSString *kUIButtonBarButtonTag;
extern NSString *kUIButtonBarButtonTarget;
extern NSString *kUIButtonBarButtonTitle;
extern NSString *kUIButtonBarButtonTitleVerticalHeight;
extern NSString *kUIButtonBarButtonTitleWidth;
extern NSString *kUIButtonBarButtonType;
/* }}} */
/* Mime Addresses {{{ */
@interface Address : NSObject {
    NSString *name_;
    NSString *email_;
}

- (void) dealloc;

- (NSString *) name;
- (NSString *) email;

+ (Address *) addressWithString:(NSString *)string;
- (Address *) initWithString:(NSString *)string;
@end

@implementation Address

- (void) dealloc {
    [name_ release];
    if (email_ != nil)
        [email_ release];
    [super dealloc];
}

- (NSString *) name {
    return name_;
}

- (NSString *) email {
    return email_;
}

+ (Address *) addressWithString:(NSString *)string {
    return [[[Address alloc] initWithString:string] autorelease];
}

- (Address *) initWithString:(NSString *)string {
    if ((self = [super init]) != nil) {
        const char *error;
        int offset;
        pcre *code = pcre_compile("^\"?(.*)\"? <([^>]*)>$", 0, &error, &offset, NULL);

        if (code == NULL) {
            fprintf(stderr, "%d:%s\n", offset, error);
            _assert(false);
        }

        pcre_extra *study = NULL;
        int capture;
        pcre_fullinfo(code, study, PCRE_INFO_CAPTURECOUNT, &capture);
        int matches[(capture + 1) * 3];

        size_t size = [string length];
        const char *data = [string UTF8String];

        if (pcre_exec(code, study, data, size, 0, 0, matches, sizeof(matches) / sizeof(matches[0])) >= 0) {
            name_ = [[NSString stringWithCString:(data + matches[2]) length:(matches[3] - matches[2])] retain];
            email_ = [[NSString stringWithCString:(data + matches[4]) length:(matches[5] - matches[4])] retain];
        } else {
            name_ = [[NSString stringWithCString:data length:size] retain];
            email_ = nil;
        }
    } return self;
}

@end
/* }}} */

/* Right Alignment {{{ */
@interface UIRightTextLabel : UITextLabel {
    float       _savedRightEdgeX;
    BOOL        _sizedtofit_flag;
}

- (void) setFrame:(CGRect)frame;
- (void) setText:(NSString *)text;
- (void) realignText;
@end

@implementation UIRightTextLabel

- (void) setFrame:(CGRect)frame {
    [super setFrame:frame];
    if (_sizedtofit_flag == NO) {
        _savedRightEdgeX = frame.origin.x;
        [self realignText];
    }
}

- (void) setText:(NSString *)text {
    [super setText:text];
    [self realignText];
}

- (void) realignText {
    CGRect oldFrame = [self frame];

    _sizedtofit_flag = YES;
    [self sizeToFit]; // shrink down size so I can right align it

    CGRect newFrame = [self frame];

    oldFrame.origin.x = _savedRightEdgeX - newFrame.size.width;
    oldFrame.size.width = newFrame.size.width;
    [super setFrame:oldFrame];
    _sizedtofit_flag = NO;
}

@end
/* }}} */
/* Linear Algebra {{{ */
inline float interpolate(float begin, float end, float fraction) {
    return (end - begin) * fraction + begin;
}
/* }}} */

/* Reset View {{{ */
@interface ResetView : UIView {
    UINavigationBar *navbar_;
    bool resetting_;
}

- (void) navigationBar:(UINavigationBar *)navbar poppedItem:(UINavigationItem *)item;

- (void) dealloc;
- (void) resetView;
- (void) _resetView;
- (NSString *) leftTitle;
- (NSString *) rightTitle;
@end

@implementation ResetView

- (void) navigationBar:(UINavigationBar *)navbar poppedItem:(UINavigationItem *)item {
    if ([[navbar_ navigationItems] count] == 1)
        [self _resetView];
}

- (void) dealloc {
    [navbar_ release];
    [super dealloc];
}

- (void) resetView {
    resetting_ = true;
    if ([[navbar_ navigationItems] count] == 1)
        [self _resetView];
    else while ([[navbar_ navigationItems] count] != 1)
        [navbar_ popNavigationItem];
    resetting_ = false;
}

- (void) _resetView {
    [navbar_ showButtonsWithLeftTitle:[self leftTitle] rightTitle:[self rightTitle]];
}

- (NSString *) leftTitle {
    return nil;
}

- (NSString *) rightTitle {
    return nil;
}

@end
/* }}} */

@class Package;

@interface Database : NSObject {
    pkgCacheFile cache_;
    pkgRecords *records_;
    pkgProblemResolver *resolver_;
    pkgAcquire *fetcher_;
    FileFd *lock_;
    SPtr<pkgPackageManager> manager_;

    id delegate_;
    Status status_;
    Progress progress_;
    int statusfd_;
}

- (void) _readStatus:(NSNumber *)fd;
- (void) _readOutput:(NSNumber *)fd;

- (Package *) packageWithName:(NSString *)name;

- (Database *) init;
- (pkgCacheFile &) cache;
- (pkgRecords *) records;
- (pkgProblemResolver *) resolver;
- (pkgAcquire &) fetcher;
- (void) reloadData;

- (void) prepare;
- (void) perform;
- (void) update;
- (void) upgrade;

- (void) setDelegate:(id)delegate;
@end

/* Package Class {{{ */
@interface Package : NSObject {
    pkgCache::PkgIterator iterator_;
    Database *database_;
    pkgRecords::Parser *parser_;
    pkgCache::VerIterator version_;
    pkgCache::VerFileIterator file_;
}

- (Package *) initWithIterator:(pkgCache::PkgIterator)iterator database:(Database *)database version:(pkgCache::VerIterator)version file:(pkgCache::VerFileIterator)file;
+ (Package *) packageWithIterator:(pkgCache::PkgIterator)iterator database:(Database *)database;

- (NSString *) name;
- (NSString *) section;
- (NSString *) latest;
- (NSString *) installed;
- (Address *) maintainer;
- (size_t) size;
- (NSString *) tagline;
- (NSString *) description;
- (NSComparisonResult) compareBySectionAndName:(Package *)package;

- (void) install;
- (void) remove;
@end

@implementation Package

- (Package *) initWithIterator:(pkgCache::PkgIterator)iterator database:(Database *)database version:(pkgCache::VerIterator)version file:(pkgCache::VerFileIterator)file {
    if ((self = [super init]) != nil) {
        iterator_ = iterator;
        database_ = database;

        version_ = version;
        file_ = file;
        parser_ = &[database_ records]->Lookup(file);
    } return self;
}

+ (Package *) packageWithIterator:(pkgCache::PkgIterator)iterator database:(Database *)database {
    for (pkgCache::VerIterator version = iterator.VersionList(); !version.end(); ++version)
        for (pkgCache::VerFileIterator file = version.FileList(); !file.end(); ++file)
            return [[[Package alloc]
                initWithIterator:iterator 
                database:database
                version:version
                file:file]
            autorelease];
    return nil;
}

- (NSString *) name {
    return [[NSString stringWithCString:iterator_.Name()] lowercaseString];
}

- (NSString *) section {
    return [NSString stringWithCString:iterator_.Section()];
}

- (NSString *) latest {
    return [NSString stringWithCString:version_.VerStr()];
}

- (NSString *) installed {
    return iterator_.CurrentVer().end() ? nil : [NSString stringWithCString:iterator_.CurrentVer().VerStr()];
}

- (Address *) maintainer {
    return [Address addressWithString:[NSString stringWithCString:parser_->Maintainer().c_str()]];
}

- (size_t) size {
    return version_->InstalledSize;
}

- (NSString *) tagline {
    return [NSString stringWithCString:parser_->ShortDesc().c_str()];
}

- (NSString *) description {
    return [NSString stringWithCString:parser_->LongDesc().c_str()];
}

- (NSComparisonResult) compareBySectionAndName:(Package *)package {
    NSComparisonResult result = [[self section] compare:[package section]];
    if (result != NSOrderedSame)
        return result;
    return [[self name] compare:[package name]];
}

- (void) install {
    pkgProblemResolver *resolver = [database_ resolver];
    resolver->Clear(iterator_);
    resolver->Protect(iterator_);
    [database_ cache]->MarkInstall(iterator_, false);
}

- (void) remove {
    pkgProblemResolver *resolver = [database_ resolver];
    resolver->Clear(iterator_);
    resolver->Protect(iterator_);
    resolver->Remove(iterator_);
    [database_ cache]->MarkDelete(iterator_, true);
}

@end
/* }}} */
/* Section Class {{{ */
@interface Section : NSObject {
    NSString *name_;
    size_t row_;
    NSMutableArray *packages_;
}

- (void) dealloc;

- (Section *) initWithName:(NSString *)name row:(size_t)row;
- (NSString *) name;
- (size_t) row;
- (void) addPackage:(Package *)package;
@end

@implementation Section

- (void) dealloc {
    [name_ release];
    [packages_ release];
    [super dealloc];
}

- (Section *) initWithName:(NSString *)name row:(size_t)row {
    if ((self = [super init]) != nil) {
        name_ = [name retain];
        row_ = row;
        packages_ = [[NSMutableArray arrayWithCapacity:16] retain];
    } return self;
}

- (NSString *) name {
    return name_;
}

- (size_t) row {
    return row_;
}

- (void) addPackage:(Package *)package {
    [packages_ addObject:package];
}

@end
/* }}} */

/* Confirmation View {{{ */
void AddTextView(NSMutableDictionary *fields, NSMutableArray *packages, NSString *key) {
    if ([packages count] == 0)
        return;

    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    float clear[] = {0, 0, 0, 0};
    float blue[] = {0, 0, 0.4, 1};

    UITextView *text([[[UITextView alloc] initWithFrame: CGRectMake(110, 3, 200, 60)] autorelease]);
    [text setEditable:NO];
    [text setTextSize:16];
    [text setBackgroundColor:CGColorCreate(space, clear)];
    [text setTextColor:CGColorCreate(space, blue)];
    [text setText:([packages count] == 0 ? @"n/a" : [packages componentsJoinedByString:@", "])];
    [text setEnabled:NO];

    CGRect frame([text frame]);
    CGSize size([text contentSize]);
    frame.size.height = size.height;
    [text setFrame:frame];

    [fields setObject:text forKey:key];
}

@protocol ConfirmationViewDelegate
- (void) cancel;
- (void) confirm;
@end

@interface ConfirmationView : UIView {
    Database *database_;
    id delegate_;
    UITransitionView *transition_;
    UIView *overlay_;
    UINavigationBar *navbar_;
    UIPreferencesTable *table_;
    NSMutableDictionary *fields_;
    UIAlertSheet *essential_;
}

- (void) dealloc;
- (void) cancel;

- (void) transitionViewDidComplete:(UITransitionView*)view fromView:(UIView*)from toView:(UIView*)to;
- (void) navigationBar:(UINavigationBar *)navbar buttonClicked:(int)button;
- (void) alertSheet:(UIAlertSheet *)sheet buttonClicked:(int)button;

- (int) numberOfGroupsInPreferencesTable:(UIPreferencesTable *)table;
- (NSString *) preferencesTable:(UIPreferencesTable *)table titleForGroup:(int)group;
- (float) preferencesTable:(UIPreferencesTable *)table heightForRow:(int)row inGroup:(int)group withProposedHeight:(float)proposed;
- (int) preferencesTable:(UIPreferencesTable *)table numberOfRowsInGroup:(int)group;
- (UIPreferencesTableCell *) preferencesTable:(UIPreferencesTable *)table cellForRow:(int)row inGroup:(int)group;

- (id) initWithView:(UIView *)view database:(Database *)database delegate:(id)delegate;

@end

@implementation ConfirmationView

- (void) dealloc {
    [transition_ release];
    [overlay_ release];
    [navbar_ release];
    [table_ release];
    [fields_ release];
    if (essential_ != nil)
        [essential_ release];
    [super dealloc];
}

- (void) cancel {
    [transition_ transition:7 toView:nil];
    [delegate_ cancel];
}

- (void) transitionViewDidComplete:(UITransitionView*)view fromView:(UIView*)from toView:(UIView*)to {
    if (from != nil && to == nil)
        [self removeFromSuperview];
}

- (void) navigationBar:(UINavigationBar *)navbar buttonClicked:(int)button {
    switch (button) {
        case 0:
            if (essential_ != nil)
                [essential_ popupAlertAnimated:YES];
            else
                [delegate_ confirm];
        break;

        case 1:
            [self cancel];
        break;
    }
}

- (void) alertSheet:(UIAlertSheet *)sheet buttonClicked:(int)button {
    [essential_ dismiss];
    [self cancel];
}

- (int) numberOfGroupsInPreferencesTable:(UIPreferencesTable *)table {
    return 2;
}

- (NSString *) preferencesTable:(UIPreferencesTable *)table titleForGroup:(int)group {
    switch (group) {
        case 0: return @"Statistics";
        case 1: return @"Modifications";

        default: _assert(false);
    }
}

- (int) preferencesTable:(UIPreferencesTable *)table numberOfRowsInGroup:(int)group {
    switch (group) {
        case 0: return 3;
        case 1: return [fields_ count];

        default: _assert(false);
    }
}

- (float) preferencesTable:(UIPreferencesTable *)table heightForRow:(int)row inGroup:(int)group withProposedHeight:(float)proposed {
    if (group != 1 || row == -1)
        return proposed;
    else {
        _assert(size_t(row) < [fields_ count]);
        fprintf(stderr, "%f\n", [[[fields_ allValues] objectAtIndex:row] contentSize].height);
        return [[[fields_ allValues] objectAtIndex:row] contentSize].height;
    }
}

- (UIPreferencesTableCell *) preferencesTable:(UIPreferencesTable *)table cellForRow:(int)row inGroup:(int)group {
    UIPreferencesTableCell *cell = [[[UIPreferencesTableCell alloc] init] autorelease];
    [cell setShowSelection:NO];

    switch (group) {
        case 0: switch (row) {
            case 0: {
                [cell setTitle:@"Downloading"];
                [cell setValue:SizeString([database_ fetcher].FetchNeeded())];
            } break;

            case 1: {
                [cell setTitle:@"Resuming At"];
                [cell setValue:SizeString([database_ fetcher].PartialPresent())];
            } break;

            case 2: {
                double size([database_ cache]->UsrSize());

                if (size < 0) {
                    [cell setTitle:@"Disk Freeing"];
                    [cell setValue:SizeString(-size)];
                } else {
                    [cell setTitle:@"Disk Using"];
                    [cell setValue:SizeString(size)];
                }
            } break;

            default: _assert(false);
        } break;

        case 1:
            _assert(size_t(row) < [fields_ count]);
            [cell setTitle:[[fields_ allKeys] objectAtIndex:row]];
            [cell addSubview:[[fields_ allValues] objectAtIndex:row]];
        break;

        default: _assert(false);
    }

    return cell;
}

- (id) initWithView:(UIView *)view database:(Database *)database delegate:(id)delegate {
    if ((self = [super initWithFrame:[view bounds]]) != nil) {
        database_ = database;
        delegate_ = delegate;

        transition_ = [[UITransitionView alloc] initWithFrame:[self bounds]];
        [self addSubview:transition_];

        overlay_ = [[UIView alloc] initWithFrame:[transition_ bounds]];

        CGSize navsize = [UINavigationBar defaultSize];
        CGRect navrect = {{0, 0}, navsize};
        CGRect bounds = [overlay_ bounds];

        navbar_ = [[UINavigationBar alloc] initWithFrame:navrect];
        [navbar_ setBarStyle:1];
        [navbar_ setDelegate:self];

        UINavigationItem *navitem = [[[UINavigationItem alloc] initWithTitle:@"Confirm"] autorelease];
        [navbar_ pushNavigationItem:navitem];
        [navbar_ showButtonsWithLeftTitle:@"Cancel" rightTitle:@"Confirm"];

        fields_ = [[NSMutableDictionary dictionaryWithCapacity:16] retain];

        NSMutableArray *installing = [NSMutableArray arrayWithCapacity:16];
        NSMutableArray *upgrading = [NSMutableArray arrayWithCapacity:16];
        NSMutableArray *removing = [NSMutableArray arrayWithCapacity:16];

        bool essential(false);

        pkgCacheFile &cache([database_ cache]);
        for (pkgCache::PkgIterator iterator = cache->PkgBegin(); !iterator.end(); ++iterator) {
            NSString *name([NSString stringWithCString:iterator.Name()]);
            if (cache[iterator].NewInstall())
                [installing addObject:name];
            else if (cache[iterator].Upgrade())
                [upgrading addObject:name];
            else if (cache[iterator].Delete()) {
                [removing addObject:name];
                if ((iterator->Flags & pkgCache::Flag::Essential) != 0)
                    essential = true;
            }
        }

        if (!essential)
            essential_ = nil;
        else {
            essential_ = [[UIAlertSheet alloc]
                initWithTitle:@"Unable to Comply"
                buttons:[NSArray arrayWithObjects:@"Okay", nil]
                defaultButtonIndex:0
                delegate:self
                context:self
            ];

            [essential_ setBodyText:@"One or more of the packages you are about to remove are marked 'Essential' and cannot be removed by Cydia. Please use apt-get."];
        }

        AddTextView(fields_, installing, @"Installing");
        AddTextView(fields_, upgrading, @"Upgrading");
        AddTextView(fields_, removing, @"Removing");

        table_ = [[UIPreferencesTable alloc] initWithFrame:CGRectMake(
            0, navsize.height, bounds.size.width, bounds.size.height - navsize.height
        )];

        [table_ setReusesTableCells:YES];
        [table_ setDataSource:self];
        [table_ reloadData];

        [overlay_ addSubview:navbar_];
        [overlay_ addSubview:table_];

        [view addSubview:self];

        [transition_ setDelegate:self];

        UIView *blank = [[[UIView alloc] initWithFrame:[transition_ bounds]] autorelease];
        [transition_ transition:0 toView:blank];
        [transition_ transition:3 toView:overlay_];
    } return self;
}

@end
/* }}} */
/* Package View {{{ */
@interface PackageView : UIView {
    UIPreferencesTable *table_;
    Package *package_;
    Database *database_;
    NSMutableArray *cells_;
    id delegate_;
}

- (void) dealloc;

- (int) numberOfGroupsInPreferencesTable:(UIPreferencesTable *)table;
- (NSString *) preferencesTable:(UIPreferencesTable *)table titleForGroup:(int)group;
- (int) preferencesTable:(UIPreferencesTable *)table numberOfRowsInGroup:(int)group;
- (UIPreferencesTableCell *) preferencesTable:(UIPreferencesTable *)table cellForRow:(int)row inGroup:(int)group;

- (BOOL) canSelectRow:(int)row;
- (void) tableRowSelected:(NSNotification *)notification;

- (id) initWithFrame:(struct CGRect)frame database:(Database *)database;
- (void) setPackage:(Package *)package;
- (void) setDelegate:(id)delegate;
@end

@implementation PackageView

- (void) dealloc {
    if (package_ != nil)
        [package_ release];
    [table_ release];
    [database_ release];
    [cells_ release];
    [super dealloc];
}

- (int) numberOfGroupsInPreferencesTable:(UIPreferencesTable *)table {
    return 2;
}

- (NSString *) preferencesTable:(UIPreferencesTable *)table titleForGroup:(int)group {
    switch (group) {
        case 0: return @"Specifics";
        case 1: return @"Description";

        default: _assert(false);
    }
}

- (int) preferencesTable:(UIPreferencesTable *)table numberOfRowsInGroup:(int)group {
    switch (group) {
        case 0: return 6;
        case 1: return 1;

        default: _assert(false);
    }
}

- (UIPreferencesTableCell *) preferencesTable:(UIPreferencesTable *)table cellForRow:(int)row inGroup:(int)group {
    UIPreferencesTableCell *cell;

    switch (group) {
        case 0: switch (row) {
            case 0:
                cell = [cells_ objectAtIndex:0];
                [cell setTitle:@"Name"];
                [cell setValue:[package_ name]];
            break;

            case 1: {
                cell = [cells_ objectAtIndex:1];
                [cell setTitle:@"Installed"];
                NSString *installed([package_ installed]);
                [cell setValue:(installed == nil ? @"n/a" : installed)];
            } break;

            case 2:
                cell = [cells_ objectAtIndex:2];
                [cell setTitle:@"Latest"];
                [cell setValue:[package_ latest]];
            break;

            case 3:
                cell = [cells_ objectAtIndex:3];
                [cell setTitle:@"Section"];
                [cell setValue:[package_ section]];
            break;

            case 4:
                cell = [cells_ objectAtIndex:4];
                [cell setTitle:@"Size"];
                [cell setValue:SizeString([package_ size])];
            break;

            case 5:
                cell = [cells_ objectAtIndex:5];
                [cell setTitle:@"Maintainer"];
                [cell setValue:[[package_ maintainer] name]];
                [cell setShowDisclosure:YES];
                [cell setShowSelection:YES];
            break;

            default: _assert(false);
        } break;

        case 1: switch (row) {
            case 0:
                cell = [cells_ objectAtIndex:6];
                [cell setTitle:nil];
                [cell setValue:[package_ tagline]];
            break;

            case 1:
                cell = [cells_ objectAtIndex:7];
                [cell setTitle:@"Description"];
                [cell setValue:[package_ description]];
            break;
        } break;

        default: _assert(false);
    }

    return cell;
}

- (BOOL) canSelectRow:(int)row {
    return YES;
}

- (void) tableRowSelected:(NSNotification *)notification {
    switch ([table_ selectedRow]) {
        case 5:
            [delegate_ openURL:[NSURL URLWithString:[NSString stringWithFormat:@"mailto:%@?subject=%@",
                [[package_ maintainer] email],
                [[NSString stringWithFormat:@"regarding apt package \"%@\"", [package_ name]] stringByAddingPercentEscapes]
            ]]];
        break;
    }
}

- (id) initWithFrame:(struct CGRect)frame database:(Database *)database {
    if ((self = [super initWithFrame:frame]) != nil) {
        database_ = [database retain];

        table_ = [[UIPreferencesTable alloc] initWithFrame:[self bounds]];
        [self addSubview:table_];

        [table_ setDataSource:self];
        [table_ setDelegate:self];

        cells_ = [[NSMutableArray arrayWithCapacity:16] retain];

        for (unsigned i = 0; i != 8; ++i) {
            UIPreferencesTableCell *cell = [[[UIPreferencesTableCell alloc] init] autorelease];
            [cell setShowSelection:NO];
            [cells_ addObject:cell];
        }
    } return self;
}

- (void) setPackage:(Package *)package {
    package_ = [package retain];
    [table_ reloadData];
}

- (void) setDelegate:(id)delegate {
    delegate_ = delegate;
}

@end
/* }}} */
/* Package Cell {{{ */
@protocol PackageCellDelegate
- (NSString *) versionWithPackage:(Package *)package;
@end

@interface PackageCell : UITableCell {
    UITextLabel *name_;
    UIRightTextLabel *version_;
    UITextLabel *description_;
}

- (void) dealloc;

- (PackageCell *) initWithPackage:(Package *)package delegate:(id)delegate;

- (void) _setSelected:(float)fraction;
- (void) setSelected:(BOOL)selected;
- (void) setSelected:(BOOL)selected withFade:(BOOL)fade;
- (void) _setSelectionFadeFraction:(float)fraction;

@end

@implementation PackageCell

- (void) dealloc {
    [name_ release];
    [version_ release];
    [description_ release];
    [super dealloc];
}

- (PackageCell *) initWithPackage:(Package *)package delegate:(id)delegate {
    if ((self = [super init]) != nil) {
        GSFontRef bold = GSFontCreateWithName("Helvetica", kGSFontTraitBold, 22);
        GSFontRef large = GSFontCreateWithName("Helvetica", kGSFontTraitNone, 16);
        GSFontRef small = GSFontCreateWithName("Helvetica", kGSFontTraitNone, 14);

        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        float clear[] = {0, 0, 0, 0};

        name_ = [[UITextLabel alloc] initWithFrame:CGRectMake(12, 7, 250, 25)];
        [name_ setText:[package name]];
        [name_ setBackgroundColor:CGColorCreate(space, clear)];
        [name_ setFont:bold];

        version_ = [[UIRightTextLabel alloc] initWithFrame:CGRectMake(290, 7, 70, 25)];
        [version_ setText:[delegate versionWithPackage:package]];
        [version_ setBackgroundColor:CGColorCreate(space, clear)];
        [version_ setFont:large];

        description_ = [[UITextLabel alloc] initWithFrame:CGRectMake(13, 35, 315, 20)];
        [description_ setText:[package tagline]];
        [description_ setBackgroundColor:CGColorCreate(space, clear)];
        [description_ setFont:small];

        [self addSubview:name_];
        [self addSubview:version_];
        [self addSubview:description_];

        CFRelease(small);
        CFRelease(large);
        CFRelease(bold);
    } return self;
}

- (void) _setSelected:(float)fraction {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();

    float black[] = {
        interpolate(0.0, 1.0, fraction),
        interpolate(0.0, 1.0, fraction),
        interpolate(0.0, 1.0, fraction),
    1.0};

    float blue[] = {
        interpolate(0.2, 1.0, fraction),
        interpolate(0.2, 1.0, fraction),
        interpolate(1.0, 1.0, fraction),
    1.0};

    float gray[] = {
        interpolate(0.4, 1.0, fraction),
        interpolate(0.4, 1.0, fraction),
        interpolate(0.4, 1.0, fraction),
    1.0};

    [name_ setColor:CGColorCreate(space, black)];
    [version_ setColor:CGColorCreate(space, blue)];
    [description_ setColor:CGColorCreate(space, gray)];
}

- (void) setSelected:(BOOL)selected {
    [self _setSelected:(selected ? 1.0 : 0.0)];
    [super setSelected:selected];
}

- (void) setSelected:(BOOL)selected withFade:(BOOL)fade {
    if (!fade)
        [self _setSelected:(selected ? 1.0 : 0.0)];
    [super setSelected:selected withFade:fade];
}

- (void) _setSelectionFadeFraction:(float)fraction {
    [self _setSelected:fraction];
    [super _setSelectionFadeFraction:fraction];
}

@end
/* }}} */
/* Sources View {{{ */
@interface SourcesView : ResetView {
    UISectionList *list_;
    Database *database_;
    id delegate_;
    NSMutableArray *sources_;
}

- (void) navigationBar:(UINavigationBar *)navbar buttonClicked:(int)button;
- (void) dealloc;
- (id) initWithFrame:(CGRect)frame database:(Database *)database;
- (void) setDelegate:(id)delegate;
- (void) reloadData;
- (NSString *) leftTitle;
- (NSString *) rightTitle;
@end

@implementation SourcesView

- (void) navigationBar:(UINavigationBar *)navbar buttonClicked:(int)button {
    switch (button) {
        case 0:
        break;

        case 1:
            [delegate_ update];
        break;
    }
}

- (void) dealloc {
    if (sources_ != nil)
        [sources_ release];
    [list_ release];
    [super dealloc];
}

- (id) initWithFrame:(CGRect)frame database:(Database *)database {
    if ((self = [super initWithFrame:frame]) != nil) {
        database_ = database;
        sources_ = nil;

        CGSize navsize = [UINavigationBar defaultSize];
        CGRect navrect = {{0, 0}, navsize};
        CGRect bounds = [self bounds];

        navbar_ = [[UINavigationBar alloc] initWithFrame:navrect];
        [self addSubview:navbar_];

        [navbar_ setBarStyle:1];
        [navbar_ setDelegate:self];

        UINavigationItem *navitem = [[[UINavigationItem alloc] initWithTitle:@"Sources"] autorelease];
        [navbar_ pushNavigationItem:navitem];

        list_ = [[UISectionList alloc] initWithFrame:CGRectMake(
            0, navsize.height, bounds.size.width, bounds.size.height - navsize.height
        )];

        [list_ setDataSource:self];
        //[list_ setShouldHideHeaderInShortLists:NO];
    } return self;
}

- (void) setDelegate:(id)delegate {
    delegate_ = delegate;
}

- (void) reloadData {
    pkgSourceList list;
    _assert(list.ReadMainList());

    sources_ = [[NSMutableArray arrayWithCapacity:16] retain];

    for (pkgSourceList::const_iterator source = list.begin(); source != list.end(); ++source) {
        metaIndex *index(*source);
        fprintf(stderr, "\"%s\" \"%s\" \"%s\" \"%s\"\n", index->GetURI().c_str(), index->GetDist().c_str(), index->GetType(), index->IsTrusted() ? "true" : "false");

        debReleaseIndex *dindex(dynamic_cast<debReleaseIndex *>(index));
        if (dindex == NULL)
            continue;

        fprintf(stderr, " \"%s\"\n", dindex->MetaIndexFile("Release").c_str());

        std::ifstream release(dindex->MetaIndexFile("Release").c_str());
        std::string line;
        while (std::getline(release, line)) {
            std::string::size_type colon(line.find(':'));
            if (colon == std::string::npos)
                continue;
            std::string name(line.substr(0, colon));
            std::string value(line.substr(colon + 1));
            while (!value.empty() && value[0] == ' ')
                value = value.substr(1);
            std::cerr << "[" << name << "|" << value << "]" << std::endl;
        }
    }

    [self resetView];
}

- (NSString *) leftTitle {
    return @"Refresh All";
}

- (NSString *) rightTitle {
    return @"Edit";
}

@end
/* }}} */

@implementation Database

- (void) _readStatus:(NSNumber *)fd {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    __gnu_cxx::stdio_filebuf<char> ib([fd intValue], std::ios::in);
    std::istream is(&ib);
    std::string line;

    const char *error;
    int offset;
    pcre *code = pcre_compile("^([^:]*):([^:]*):([^:]*):(.*)$", 0, &error, &offset, NULL);

    pcre_extra *study = NULL;
    int capture;
    pcre_fullinfo(code, study, PCRE_INFO_CAPTURECOUNT, &capture);
    int matches[(capture + 1) * 3];

    while (std::getline(is, line)) {
        const char *data(line.c_str());

        _assert(pcre_exec(code, study, data, line.size(), 0, 0, matches, sizeof(matches) / sizeof(matches[0])) >= 0);

        std::istringstream buffer(line.substr(matches[6], matches[7] - matches[6]));
        float percent;
        buffer >> percent;
        [delegate_ setPercent:(percent / 100)];

        NSString *string = [NSString stringWithCString:(data + matches[8]) length:(matches[9] - matches[8])];
        std::string type(line.substr(matches[2], matches[3] - matches[2]));

        if (type == "pmerror")
            [delegate_ setError:string];
        else if (type == "pmstatus")
            [delegate_ setTitle:string];
        else if (type == "pmconffile")
            ;
        else _assert(false);
    }

    [pool release];
}

- (void) _readOutput:(NSNumber *)fd {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    __gnu_cxx::stdio_filebuf<char> ib([fd intValue], std::ios::in);
    std::istream is(&ib);
    std::string line;

    while (std::getline(is, line))
        [delegate_ addOutput:[NSString stringWithCString:line.c_str()]];

    [pool release];
}

- (Package *) packageWithName:(NSString *)name {
    pkgCache::PkgIterator iterator(cache_->FindPkg([name cString]));
    return iterator.end() ? nil : [Package packageWithIterator:iterator database:self];
}

- (Database *) init {
    if ((self = [super init]) != nil) {
        records_ = NULL;
        resolver_ = NULL;
        fetcher_ = NULL;
        lock_ = NULL;

        int fds[2];

        _assert(pipe(fds) != -1);
        statusfd_ = fds[1];

        [NSThread
            detachNewThreadSelector:@selector(_readStatus:)
            toTarget:self
            withObject:[[NSNumber numberWithInt:fds[0]] retain]
        ];

        _assert(pipe(fds) != -1);
        _assert(dup2(fds[1], 1) != -1);
        _assert(close(fds[1]) != -1);

        [NSThread
            detachNewThreadSelector:@selector(_readOutput:)
            toTarget:self
            withObject:[[NSNumber numberWithInt:fds[0]] retain]
        ];
    } return self;
}

- (pkgCacheFile &) cache {
    return cache_;
}

- (pkgRecords *) records {
    return records_;
}

- (pkgProblemResolver *) resolver {
    return resolver_;
}

- (pkgAcquire &) fetcher {
    return *fetcher_;
}

- (void) reloadData {
    _error->Discard();
    manager_ = NULL;
    delete lock_;
    delete fetcher_;
    delete resolver_;
    delete records_;
    cache_.Close();
    cache_.Open(progress_, true);
    records_ = new pkgRecords(cache_);
    resolver_ = new pkgProblemResolver(cache_);
    fetcher_ = new pkgAcquire(&status_);
    lock_ = NULL;
}

- (void) prepare {
    pkgRecords records(cache_);

    lock_ = new FileFd();
    lock_->Fd(GetLock(_config->FindDir("Dir::Cache::Archives") + "lock"));
    _assert(!_error->PendingError());

    pkgSourceList list;
    _assert(list.ReadMainList());

    manager_ = (_system->CreatePM(cache_));
    _assert(manager_->GetArchives(fetcher_, &list, &records));
    _assert(!_error->PendingError());
}

- (void) perform {
    if (fetcher_->Run(PulseInterval_) != pkgAcquire::Continue)
        return;

    _system->UnLock();
    pkgPackageManager::OrderResult result = manager_->DoInstall(statusfd_);

    if (result == pkgPackageManager::Failed)
        return;
    if (_error->PendingError())
        return;
    if (result != pkgPackageManager::Completed)
        return;
}

- (void) update {
    pkgSourceList list;
    _assert(list.ReadMainList());

    FileFd lock;
    lock.Fd(GetLock(_config->FindDir("Dir::State::Lists") + "lock"));
    _assert(!_error->PendingError());

    pkgAcquire fetcher(&status_);
    _assert(list.GetIndexes(&fetcher));
    _assert(fetcher.Run(PulseInterval_) != pkgAcquire::Failed);

    bool failed = false;
    for (pkgAcquire::ItemIterator item = fetcher.ItemsBegin(); item != fetcher.ItemsEnd(); item++)
        if ((*item)->Status != pkgAcquire::Item::StatDone) {
            (*item)->Finished();
            failed = true;
        }

    if (!failed && _config->FindB("APT::Get::List-Cleanup", true) == true) {
        _assert(fetcher.Clean(_config->FindDir("Dir::State::lists")));
        _assert(fetcher.Clean(_config->FindDir("Dir::State::lists") + "partial/"));
    }
}

- (void) upgrade {
    _assert(cache_->DelCount() == 0 && cache_->InstCount() == 0);
    _assert(pkgApplyStatus(cache_));

    if (cache_->BrokenCount() != 0) {
        _assert(pkgFixBroken(cache_));
        _assert(cache_->BrokenCount() == 0);
        _assert(pkgMinimizeUpgrade(cache_));
    }

    _assert(pkgDistUpgrade(cache_));

    //InstallPackages(cache_, true);
}

- (void) setDelegate:(id)delegate {
    delegate_ = delegate;
    status_.setDelegate(delegate);
    progress_.setDelegate(delegate);
}

@end

/* Progress Data {{{ */
@interface ProgressData : NSObject {
    SEL selector_;
    id target_;
    id object_;
}

- (ProgressData *) initWithSelector:(SEL)selector target:(id)target object:(id)object;

- (SEL) selector;
- (id) target;
- (id) object;
@end

@implementation ProgressData

- (ProgressData *) initWithSelector:(SEL)selector target:(id)target object:(id)object {
    if ((self = [super init]) != nil) {
        selector_ = selector;
        target_ = target;
        object_ = object;
    } return self;
}

- (SEL) selector {
    return selector_;
}

- (id) target {
    return target_;
}

- (id) object {
    return object_;
}

@end
/* }}} */
/* Progress View {{{ */
@interface ProgressView : UIView <
    ProgressDelegate
> {
    UIView *view_;
    UIView *background_;
    UITransitionView *transition_;
    UIView *overlay_;
    UINavigationBar *navbar_;
    UIProgressBar *progress_;
    UITextView *output_;
    UITextLabel *status_;
    id delegate_;
    UIAlertSheet *alert_;
}

- (void) dealloc;

- (ProgressView *) initWithFrame:(struct CGRect)frame delegate:(id)delegate;
- (void) setContentView:(UIView *)view;
- (void) resetView;

- (void) alertSheet:(UIAlertSheet *)sheet buttonClicked:(int)button;

- (void) _retachThread;
- (void) _detachNewThreadData:(ProgressData *)data;
- (void) detachNewThreadSelector:(SEL)selector toTarget:(id)target withObject:(id)object;

- (void) setError:(NSString *)error;
- (void) _setError:(NSString *)error;

- (void) setTitle:(NSString *)title;
- (void) _setTitle:(NSString *)title;

- (void) setPercent:(float)percent;
- (void) _setPercent:(NSNumber *)percent;

- (void) addOutput:(NSString *)output;
- (void) _addOutput:(NSString *)output;

- (void) setStatusFail;
@end

@protocol ProgressViewDelegate
- (void) progressViewIsComplete:(ProgressView *)sender;
@end

@implementation ProgressView

- (void) dealloc {
    [view_ release];
    [background_ release];
    [transition_ release];
    [overlay_ release];
    [navbar_ release];
    [progress_ release];
    [output_ release];
    [status_ release];
    [super dealloc];
}

- (ProgressView *) initWithFrame:(struct CGRect)frame delegate:(id)delegate {
    if ((self = [super initWithFrame:frame]) != nil) {
        delegate_ = delegate;
        alert_ = nil;

        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        float black[] = {0.0, 0.0, 0.0, 1.0};
        float white[] = {1.0, 1.0, 1.0, 1.0};
        float clear[] = {0.0, 0.0, 0.0, 0.0};

        background_ = [[UIView alloc] initWithFrame:[self bounds]];
        [background_ setBackgroundColor:CGColorCreate(space, black)];
        [self addSubview:background_];

        transition_ = [[UITransitionView alloc] initWithFrame:[self bounds]];
        [self addSubview:transition_];

        overlay_ = [[UIView alloc] initWithFrame:[transition_ bounds]];

        CGSize navsize = [UINavigationBar defaultSize];
        CGRect navrect = {{0, 0}, navsize};

        navbar_ = [[UINavigationBar alloc] initWithFrame:navrect];
        [overlay_ addSubview:navbar_];

        [navbar_ setBarStyle:1];
        [navbar_ setDelegate:self];

        UINavigationItem *navitem = [[[UINavigationItem alloc] initWithTitle:@"Running..."] autorelease];
        [navbar_ pushNavigationItem:navitem];

        CGRect bounds = [overlay_ bounds];
        CGSize prgsize = [UIProgressBar defaultSize];

        CGRect prgrect = {{
            (bounds.size.width - prgsize.width) / 2,
            bounds.size.height - prgsize.height - 20
        }, prgsize};

        progress_ = [[UIProgressBar alloc] initWithFrame:prgrect];
        [overlay_ addSubview:progress_];

        status_ = [[UITextLabel alloc] initWithFrame:CGRectMake(
            10,
            bounds.size.height - prgsize.height - 50,
            bounds.size.width - 20,
            24
        )];

        [status_ setColor:CGColorCreate(space, white)];
        [status_ setBackgroundColor:CGColorCreate(space, clear)];

        [status_ setCentersHorizontally:YES];
        //[status_ setFont:font];

        output_ = [[UITextView alloc] initWithFrame:CGRectMake(
            10,
            navrect.size.height + 20,
            bounds.size.width - 20,
            bounds.size.height - navsize.height - 62 - navrect.size.height
        )];

        //[output_ setTextFont:@"Courier New"];
        [output_ setTextSize:12];

        [output_ setTextColor:CGColorCreate(space, white)];
        [output_ setBackgroundColor:CGColorCreate(space, clear)];

        [output_ setMarginTop:0];
        [output_ setAllowsRubberBanding:YES];

        [overlay_ addSubview:output_];
        [overlay_ addSubview:status_];

        [progress_ setStyle:0];
    } return self;
}

- (void) setContentView:(UIView *)view {
    view_ = view;
}

- (void) resetView {
    [transition_ transition:6 toView:view_];
}

- (void) alertSheet:(UIAlertSheet *)sheet buttonClicked:(int)button {
    [alert_ dismiss];
    [alert_ release];
    alert_ = nil;
}

- (void) _retachThread {
    [delegate_ progressViewIsComplete:self];
    [self resetView];
}

- (void) _detachNewThreadData:(ProgressData *)data {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    [[data target] performSelector:[data selector] withObject:[data object]];
    [self performSelectorOnMainThread:@selector(_retachThread) withObject:nil waitUntilDone:YES];

    [data release];
    [pool release];
}

- (void) detachNewThreadSelector:(SEL)selector toTarget:(id)target withObject:(id)object {
    [status_ setText:nil];
    [output_ setText:@""];
    [progress_ setProgress:0];

    [transition_ transition:6 toView:overlay_];

    [NSThread
        detachNewThreadSelector:@selector(_detachNewThreadData:)
        toTarget:self
        withObject:[[ProgressData alloc]
            initWithSelector:selector
            target:target
            object:object
        ]
    ];
}

- (void) setStatusFail {
}

- (void) setError:(NSString *)error {
    [self
        performSelectorOnMainThread:@selector(_setError:)
        withObject:error
        waitUntilDone:YES
    ];
}

- (void) _setError:(NSString *)error {
    _assert(alert_ == nil);

    alert_ = [[UIAlertSheet alloc]
        initWithTitle:@"Package Error"
        buttons:[NSArray arrayWithObjects:@"Okay", nil]
        defaultButtonIndex:0
        delegate:self
        context:self
    ];

    [alert_ setBodyText:error];
    [alert_ popupAlertAnimated:YES];
}

- (void) setTitle:(NSString *)title {
    [self
        performSelectorOnMainThread:@selector(_setTitle:)
        withObject:title
        waitUntilDone:YES
    ];
}

- (void) _setTitle:(NSString *)title {
    [status_ setText:[title stringByAppendingString:@"..."]];
}

- (void) setPercent:(float)percent {
    [self
        performSelectorOnMainThread:@selector(_setPercent:)
        withObject:[NSNumber numberWithFloat:percent]
        waitUntilDone:YES
    ];
}

- (void) _setPercent:(NSNumber *)percent {
    [progress_ setProgress:[percent floatValue]];
}

- (void) addOutput:(NSString *)output {
    [self
        performSelectorOnMainThread:@selector(_addOutput:)
        withObject:output
        waitUntilDone:YES
    ];
}

- (void) _addOutput:(NSString *)output {
    [output_ setText:[NSString stringWithFormat:@"%@\n%@", [output_ text], output]];
    CGSize size = [output_ contentSize];
    CGRect rect = {{0, size.height}, {size.width, 0}};
    [output_ scrollRectToVisible:rect animated:YES];
}

@end
/* }}} */

@protocol PackagesViewDelegate
- (void) perform;
- (void) update;
- (void) openURL:(NSString *)url;
@end

/* PackagesView {{{ */
@interface PackagesView : ResetView <
    PackageCellDelegate
> {
    Database *database_;
    NSMutableArray *packages_;
    NSMutableArray *sections_;
    id delegate_;
    UISectionList *list_;
    UITransitionView *transition_;
    Package *package_;
    NSString *pkgname_;
    PackageView *pkgview_;
}

- (int) numberOfSectionsInSectionList:(UISectionList *)list;
- (NSString *) sectionList:(UISectionList *)list titleForSection:(int)section;
- (int) sectionList:(UISectionList *)list rowForSection:(int)section;

- (int) numberOfRowsInTable:(UITable *)table;
- (float) table:(UITable *)table heightForRow:(int)row;
- (UITableCell *) table:(UITable *)table cellForRow:(int)row column:(UITableColumn *)col;
- (BOOL) table:(UITable *)table showDisclosureForRow:(int)row;
- (void) tableRowSelected:(NSNotification*)notification;

- (void) navigationBar:(UINavigationBar *)navbar buttonClicked:(int)button;
- (void) navigationBar:(UINavigationBar *)navbar poppedItem:(UINavigationItem *)item;

- (id) initWithFrame:(struct CGRect)frame database:(Database *)database;
- (void) setDelegate:(id)delegate;
- (void) deselect;
- (void) reloadData:(BOOL)reset;

- (NSString *) title;
- (void) perform:(Package *)package;
- (void) addPackage:(Package *)package;
- (NSString *) versionWithPackage:(Package *)package;
@end

@implementation PackagesView

- (int) numberOfSectionsInSectionList:(UISectionList *)list {
    return [sections_ count];
}

- (NSString *) sectionList:(UISectionList *)list titleForSection:(int)section {
    return [[sections_ objectAtIndex:section] name];
}

- (int) sectionList:(UISectionList *)list rowForSection:(int)section {
    return [[sections_ objectAtIndex:section] row];
}

- (int) numberOfRowsInTable:(UITable *)table {
    return [packages_ count];
}

- (float) table:(UITable *)table heightForRow:(int)row {
    return 64;
}

- (UITableCell *) table:(UITable *)table cellForRow:(int)row column:(UITableColumn *)col {
    Package *package = [packages_ objectAtIndex:row];
    PackageCell *cell = [[[PackageCell alloc] initWithPackage:package delegate:self] autorelease];
    return cell;
}

- (BOOL) table:(UITable *)table showDisclosureForRow:(int)row {
    return YES;
}

- (void) tableRowSelected:(NSNotification*)notification {
    int row = [[list_ table] selectedRow];
    if (row == INT_MAX)
        return;

    package_ = [packages_ objectAtIndex:row];
    pkgname_ = [[package_ name] retain];

    UINavigationItem *navitem = [[UINavigationItem alloc] initWithTitle:[package_ name]];
    [navbar_ pushNavigationItem:navitem];

    [navbar_ showButtonsWithLeftTitle:nil rightTitle:[self title]];

    [pkgview_ setPackage:package_];
    [transition_ transition:1 toView:pkgview_];
}

- (void) navigationBar:(UINavigationBar *)navbar buttonClicked:(int)button {
    if (button == 0) {
        [self perform:package_];

        pkgProblemResolver *resolver = [database_ resolver];

        resolver->InstallProtect();
        if (!resolver->Resolve(true))
            _error->Discard();

        [delegate_ perform];
    }
}

- (void) navigationBar:(UINavigationBar *)navbar poppedItem:(UINavigationItem *)item {
    [self deselect];
    [super navigationBar:navbar poppedItem:item];
}

- (id) initWithFrame:(struct CGRect)frame database:(Database *)database {
    if ((self = [super initWithFrame:frame]) != nil) {
        database_ = [database retain];

        struct CGRect bounds = [self bounds];
        CGSize navsize = [UINavigationBar defaultSize];
        CGRect navrect = {{0, 0}, navsize};

        navbar_ = [[UINavigationBar alloc] initWithFrame:navrect];
        [self addSubview:navbar_];

        [navbar_ setBarStyle:1];
        [navbar_ setDelegate:self];

        UINavigationItem *navitem = [[[UINavigationItem alloc] initWithTitle:[self title]] autorelease];
        [navbar_ pushNavigationItem:navitem];
        [navitem setBackButtonTitle:@"Packages"];

        transition_ = [[UITransitionView alloc] initWithFrame:CGRectMake(
            bounds.origin.x, bounds.origin.y + navsize.height, bounds.size.width, bounds.size.height - navsize.height
        )];

        [self addSubview:transition_];

        list_ = [[UISectionList alloc] initWithFrame:[transition_ bounds] showSectionIndex:NO];
        [list_ setDataSource:self];
        [list_ setShouldHideHeaderInShortLists:NO];

        [transition_ transition:0 toView:list_];

        UITableColumn *column = [[UITableColumn alloc]
            initWithTitle:@"Name"
            identifier:@"name"
            width:frame.size.width
        ];

        UITable *table = [list_ table];
        [table setSeparatorStyle:1];
        [table addTableColumn:column];
        [table setDelegate:self];

        pkgview_ = [[PackageView alloc] initWithFrame:[transition_ bounds] database:database_];
    } return self;
}

- (void) setDelegate:(id)delegate {
    delegate_ = delegate;
    [pkgview_ setDelegate:delegate];
}

- (void) deselect {
    [transition_ transition:(resetting_ ? 0 : 2) toView:list_];
    UITable *table = [list_ table];
    [table selectRow:-1 byExtendingSelection:NO withFade:(resetting_ ? NO : YES)];
    package_ = nil;
}

- (void) reloadData:(BOOL)reset {
    packages_ = [[NSMutableArray arrayWithCapacity:16] retain];

    if (sections_ != nil) {
        [sections_ release];
        sections_ = nil;
    }

    for (pkgCache::PkgIterator iterator = [database_ cache]->PkgBegin(); !iterator.end(); ++iterator)
        if (Package *package = [Package packageWithIterator:iterator database:database_])
            [self addPackage:package];

    [packages_ sortUsingSelector:@selector(compareBySectionAndName:)];
    sections_ = [[NSMutableArray arrayWithCapacity:16] retain];

    Section *section = nil;
    for (size_t offset = 0, count = [packages_ count]; offset != count; ++offset) {
        Package *package = [packages_ objectAtIndex:offset];
        NSString *name = [package section];

        if (section == nil || ![[section name] isEqual:name]) {
            section = [[Section alloc] initWithName:name row:offset];
            [sections_ addObject:section];
        }

        [section addPackage:package];
    }

    [list_ reloadData];
    if (reset)
        [self resetView];
    else if (package_ != nil) {
        package_ = [database_ packageWithName:pkgname_];
        [pkgview_ setPackage:package_];
    }
}

- (NSString *) title {
    return nil;
}

- (void) perform:(Package *)package {
}

- (void) addPackage:(Package *)package {
    [packages_ addObject:package];
}

- (NSString *) versionWithPackage:(Package *)package {
    return nil;
}

@end
/* }}} */

/* InstallView {{{ */
@interface InstallView : PackagesView {
}

- (NSString *) title;
- (void) addPackage:(Package *)package;
- (void) perform:(Package *)package;
- (NSString *) versionWithPackage:(Package *)package;
@end

@implementation InstallView

- (NSString *) title {
    return @"Install";
}

- (void) addPackage:(Package *)package {
    if ([package installed] == nil)
        [super addPackage:package];
}

- (void) perform:(Package *)package {
    [package install];
}

- (NSString *) versionWithPackage:(Package *)package {
    return [package latest];
}

@end
/* }}} */
/* UpgradeView {{{ */
@interface UpgradeView : PackagesView {
}

- (NSString *) title;
- (NSString *) leftTitle;
- (void) addPackage:(Package *)package;
- (void) perform:(Package *)package;
- (NSString *) versionWithPackage:(Package *)package;
@end

@implementation UpgradeView

- (NSString *) title {
    return @"Upgrade";
}

- (NSString *) leftTitle {
    return @"Upgrade All";
}

- (void) addPackage:(Package *)package {
    NSString *installed = [package installed];
    if (installed != nil && [[package latest] compare:installed] != NSOrderedSame)
        [super addPackage:package];
}

- (void) perform:(Package *)package {
    [package install];
}

- (NSString *) versionWithPackage:(Package *)package {
    return [package latest];
}

@end
/* }}} */
/* UninstallView {{{ */
@interface UninstallView : PackagesView {
}

- (NSString *) title;
- (void) addPackage:(Package *)package;
- (void) perform:(Package *)package;
- (NSString *) versionWithPackage:(Package *)package;
@end

@implementation UninstallView

- (NSString *) title {
    return @"Uninstall";
}

- (void) addPackage:(Package *)package {
    if ([package installed] != nil)
        [super addPackage:package];
}

- (void) perform:(Package *)package {
    [package remove];
}

- (NSString *) versionWithPackage:(Package *)package {
    return [package installed];
}

@end
/* }}} */

@interface Cydia : UIApplication <
    ConfirmationViewDelegate,
    PackagesViewDelegate,
    ProgressViewDelegate
> {
    UIWindow *window_;
    UIView *underlay_;
    UIView *overlay_;
    UITransitionView *transition_;
    UIButtonBar *buttonbar_;

    UIAlertSheet *alert_;
    ConfirmationView *confirm_;

    Database *database_;
    ProgressView *progress_;

    UIView *featured_;
    UINavigationBar *navbar_;
    UIScroller *scroller_;
    UIWebView *webview_;
    NSURL *url_;

    InstallView *install_;
    UpgradeView *upgrade_;
    UninstallView *uninstall_;
    SourcesView *sources_;
}

- (void) loadNews;
- (void) reloadData:(BOOL)reset;
- (void) perform;
- (void) cancel;
- (void) confirm;
- (void) update;

- (void) progressViewIsComplete:(ProgressView *)progress;

- (void) navigationBar:(UINavigationBar *)navbar buttonClicked:(int)button;
- (void) alertSheet:(UIAlertSheet *)sheet buttonClicked:(int)button;
- (void) buttonBarItemTapped:(id)sender;

- (void) view:(UIView *)sender didSetFrame:(CGRect)frame;
- (void) view:(UIView *)view didDrawInRect:(CGRect)rect duration:(float)duration;

- (void) applicationDidFinishLaunching:(id)unused;
@end

#include <objc/objc-class.h>

@implementation Cydia

- (void) loadNews {
    NSMutableURLRequest *request = [NSMutableURLRequest
        requestWithURL:url_
        cachePolicy:NSURLRequestReloadIgnoringCacheData
        timeoutInterval:30.0
    ];

    [request addValue:[NSString stringWithCString:Machine_] forHTTPHeaderField:@"X-Machine"];
    [request addValue:[NSString stringWithCString:SerialNumber_] forHTTPHeaderField:@"X-Serial-Number"];

    [webview_ loadRequest:request];
}

- (void) reloadData:(BOOL)reset {
    [database_ reloadData];
    [install_ reloadData:reset];
    [upgrade_ reloadData:reset];
    [uninstall_ reloadData:reset];
    [sources_ reloadData];
}

- (void) perform {
    [database_ prepare];
    confirm_ = [[ConfirmationView alloc] initWithView:underlay_ database:database_ delegate:self];
}

- (void) cancel {
    [self reloadData:NO];
    [confirm_ release];
    confirm_ = nil;
}

- (void) confirm {
    [overlay_ removeFromSuperview];

    [progress_
        detachNewThreadSelector:@selector(perform)
        toTarget:database_
        withObject:nil
    ];
}

- (void) update {
    [progress_
        detachNewThreadSelector:@selector(update)
        toTarget:database_
        withObject:nil
    ];
}

- (void) progressViewIsComplete:(ProgressView *)progress {
    [self reloadData:YES];

    if (confirm_ != nil) {
        [underlay_ addSubview:overlay_];
        [confirm_ removeFromSuperview];
        [confirm_ release];
        confirm_ = nil;
    }
}

- (void) navigationBar:(UINavigationBar *)navbar buttonClicked:(int)button {
    switch (button) {
        case 0:
            [self loadNews];
        break;

        case 1:
            _assert(alert_ == nil);

            alert_ = [[UIAlertSheet alloc]
                initWithTitle:@"About Cydia Packager"
                buttons:[NSArray arrayWithObjects:@"Close", nil]
                defaultButtonIndex:0
                delegate:self
                context:self
            ];

            [alert_ setBodyText:
                @"Copyright (C) 2007\n"
                "Jay Freeman (saurik)\n"
                "saurik@saurik.com\n"
                "http://www.saurik.com/\n"
                "\n"
                "The Okori Group\n"
                "http://www.theokorigroup.com/\n"
                "\n"
                "College of Creative Studies,\n"
                "University of California,\n"
                "Santa Barbara\n"
                "http://www.ccs.ucsb.edu/\n"
                "\n"
                "Special Thanks:\n"
                "bad_, BHSPitMonkey, Cobra, core,\n"
                "Corona, cromas, Darken, dtzWill,\n"
                "francis, Godores, jerry, Kingstone,\n"
                "lounger, rockabilly, tman, Wbiggs"
            ];

            [alert_ presentSheetFromButtonBar:buttonbar_];
        break;
    }
}

- (void) alertSheet:(UIAlertSheet *)sheet buttonClicked:(int)button {
    [alert_ dismiss];
    [alert_ release];
    alert_ = nil;
}

- (void) buttonBarItemTapped:(id)sender {
    UIView *view;

    switch ([sender tag]) {
        case 1: view = featured_; break;
        case 2: view = install_; break;
        case 3: view = upgrade_; break;
        case 4: view = uninstall_; break;
        case 5: view = sources_; break;

        default:
            _assert(false);
    }

    if ([view respondsToSelector:@selector(resetView)])
        [(id) view resetView];
    [transition_ transition:0 toView:view];
}

- (void) view:(UIView *)view didSetFrame:(CGRect)frame {
    [scroller_ setContentSize:frame.size];
}

- (void) view:(UIView *)view didDrawInRect:(CGRect)rect duration:(float)duration {
    [scroller_ setContentSize:[webview_ bounds].size];
}

- (void) applicationDidFinishLaunching:(id)unused {
    _assert(pkgInitConfig(*_config));
    _assert(pkgInitSystem(*_config, _system));

    alert_ = nil;
    confirm_ = nil;

    CGRect screenrect = [UIHardware fullScreenApplicationContentRect];
    window_ = [[UIWindow alloc] initWithContentRect:screenrect];

    [window_ orderFront: self];
    [window_ makeKey: self];
    [window_ _setHidden: NO];

    progress_ = [[ProgressView alloc] initWithFrame:[window_ bounds] delegate:self];
    [window_ setContentView:progress_];

    underlay_ = [[UIView alloc] initWithFrame:[progress_ bounds]];
    [progress_ setContentView:underlay_];

    overlay_ = [[UIView alloc] initWithFrame:[underlay_ bounds]];
    [underlay_ addSubview:overlay_];

    transition_ = [[UITransitionView alloc] initWithFrame:CGRectMake(
        0, 0, screenrect.size.width, screenrect.size.height - 48
    )];

    [overlay_ addSubview:transition_];

    featured_ = [[UIView alloc] initWithFrame:[transition_ bounds]];

    CGSize navsize = [UINavigationBar defaultSize];
    CGRect navrect = {{0, 0}, navsize};

    navbar_ = [[UINavigationBar alloc] initWithFrame:navrect];
    [featured_ addSubview:navbar_];

    [navbar_ setBarStyle:1];
    [navbar_ setDelegate:self];

    [navbar_ showButtonsWithLeftTitle:@"About" rightTitle:@"Reload"];

    UINavigationItem *navitem = [[UINavigationItem alloc] initWithTitle:@"Featured"];
    [navbar_ pushNavigationItem:navitem];

    struct CGRect subbounds = [featured_ bounds];
    subbounds.origin.y += navsize.height;
    subbounds.size.height -= navsize.height;

    UIImageView *pinstripe = [[UIImageView alloc] initWithFrame:subbounds];
    [pinstripe setImage:[UIImage applicationImageNamed:@"pinstripe.png"]];
    [featured_ addSubview:pinstripe];

    scroller_ = [[UIScroller alloc] initWithFrame:subbounds];
    [featured_ addSubview:scroller_];

    [scroller_ setScrollingEnabled:YES];
    [scroller_ setAdjustForContentSizeChange:YES];
    [scroller_ setClipsSubviews:YES];
    [scroller_ setAllowsRubberBanding:YES];
    [scroller_ setScrollDecelerationFactor:0.99];
    [scroller_ setDelegate:self];

    webview_ = [[UIWebView alloc] initWithFrame:[scroller_ bounds]];
    [scroller_ addSubview:webview_];

    [webview_ setTilingEnabled:YES];
    [webview_ setTileSize:CGSizeMake(screenrect.size.width, 500)];
    [webview_ setAutoresizes:YES];
    [webview_ setDelegate:self];

    NSArray *buttonitems = [NSArray arrayWithObjects:
        [NSDictionary dictionaryWithObjectsAndKeys:
            @"buttonBarItemTapped:", kUIButtonBarButtonAction,
            @"featured-up.png", kUIButtonBarButtonInfo,
            @"featured-dn.png", kUIButtonBarButtonSelectedInfo,
            [NSNumber numberWithInt:1], kUIButtonBarButtonTag,
            self, kUIButtonBarButtonTarget,
            @"Featured", kUIButtonBarButtonTitle,
            @"0", kUIButtonBarButtonType,
        nil],

        [NSDictionary dictionaryWithObjectsAndKeys:
            @"buttonBarItemTapped:", kUIButtonBarButtonAction,
            @"install-up.png", kUIButtonBarButtonInfo,
            @"install-dn.png", kUIButtonBarButtonSelectedInfo,
            [NSNumber numberWithInt:2], kUIButtonBarButtonTag,
            self, kUIButtonBarButtonTarget,
            @"Install", kUIButtonBarButtonTitle,
            @"0", kUIButtonBarButtonType,
        nil],

        [NSDictionary dictionaryWithObjectsAndKeys:
            @"buttonBarItemTapped:", kUIButtonBarButtonAction,
            @"upgrade-up.png", kUIButtonBarButtonInfo,
            @"upgrade-dn.png", kUIButtonBarButtonSelectedInfo,
            [NSNumber numberWithInt:3], kUIButtonBarButtonTag,
            self, kUIButtonBarButtonTarget,
            @"Upgrade", kUIButtonBarButtonTitle,
            @"0", kUIButtonBarButtonType,
        nil],

        [NSDictionary dictionaryWithObjectsAndKeys:
            @"buttonBarItemTapped:", kUIButtonBarButtonAction,
            @"uninstall-up.png", kUIButtonBarButtonInfo,
            @"uninstall-dn.png", kUIButtonBarButtonSelectedInfo,
            [NSNumber numberWithInt:4], kUIButtonBarButtonTag,
            self, kUIButtonBarButtonTarget,
            @"Uninstall", kUIButtonBarButtonTitle,
            @"0", kUIButtonBarButtonType,
        nil],

        [NSDictionary dictionaryWithObjectsAndKeys:
            @"buttonBarItemTapped:", kUIButtonBarButtonAction,
            @"sources-up.png", kUIButtonBarButtonInfo,
            @"sources-dn.png", kUIButtonBarButtonSelectedInfo,
            [NSNumber numberWithInt:5], kUIButtonBarButtonTag,
            self, kUIButtonBarButtonTarget,
            @"Sources", kUIButtonBarButtonTitle,
            @"0", kUIButtonBarButtonType,
        nil],
    nil];

    buttonbar_ = [[UIButtonBar alloc]
        initInView:overlay_
        withFrame:CGRectMake(
            0, screenrect.size.height - 48,
            screenrect.size.width, 48
        )
        withItemList:buttonitems
    ];

    [buttonbar_ setDelegate:self];
    [buttonbar_ setBarStyle:1];
    [buttonbar_ setButtonBarTrackingMode:2];

    int buttons[5] = {1, 2, 3, 4, 5};
    [buttonbar_ registerButtonGroup:0 withButtons:buttons withCount:5];
    [buttonbar_ showButtonGroup:0 withDuration:0];

    for (int i = 0; i != 5; ++i)
        [[buttonbar_ viewWithTag:(i + 1)] setFrame:CGRectMake(
            i * 64 + 2, 1, 60, 48
        )];

    [buttonbar_ showSelectionForButton:1];
    [transition_ transition:0 toView:featured_];

    [overlay_ addSubview:buttonbar_];

    database_ = [[Database alloc] init];
    [database_ setDelegate:progress_];

    install_ = [[InstallView alloc] initWithFrame:[transition_ bounds] database:database_];
    [install_ setDelegate:self];

    upgrade_ = [[UpgradeView alloc] initWithFrame:[transition_ bounds] database:database_];
    [upgrade_ setDelegate:self];

    uninstall_ = [[UninstallView alloc] initWithFrame:[transition_ bounds] database:database_];
    [uninstall_ setDelegate:self];

    sources_ = [[SourcesView alloc] initWithFrame:[transition_ bounds] database:database_];
    [sources_ setDelegate:self];

#if 0

    UIAlertSheet *alert = [[UIAlertSheet alloc]
        initWithTitle:@"Alert Title"
        buttons:[NSArray arrayWithObjects:@"Yes", nil]
        defaultButtonIndex:0
        delegate:self
        context:self
    ];

    NSLog(@"%p\n", [alert table]);
    [[alert table] setDelegate:self];
    [[alert table] reloadData];

    [alert addTextFieldWithValue:@"Title" label:@"Label"];
    [alert setShowsOverSpringBoardAlerts:YES];
    [alert setBodyText:@"This is an alert."];
    [alert presentSheetFromButtonBar:buttonbar_];
    //[alert popupAlertAnimated:YES];

#endif

    [self reloadData:NO];
    [progress_ resetView];

    Package *package([database_ packageWithName:@"cydia"]);
    NSString *application = package == nil ? @"Cydia" : [NSString stringWithFormat:@"Cydia/%@", [package installed]];
    WebView *webview = [webview_ webView];
    [webview setApplicationNameForUserAgent:application];

    url_ = [NSURL URLWithString:@"http://cydia.saurik.com/"];
    [self loadNews];
}

@end

int main(int argc, char *argv[]) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    size_t size;
    sysctlbyname("hw.machine", NULL, &size, NULL, 0);
    char *machine = new char[size];
    sysctlbyname("hw.machine", machine, &size, NULL, 0);
    Machine_ = machine;

    if (CFMutableDictionaryRef dict = IOServiceMatching("IOPlatformExpertDevice"))
        if (io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, dict)) {
            if (CFTypeRef serial = IORegistryEntryCreateCFProperty(service, CFSTR(kIOPlatformSerialNumberKey), kCFAllocatorDefault, 0)) {
                SerialNumber_ = strdup(CFStringGetCStringPtr((CFStringRef) serial, CFStringGetSystemEncoding()));
                CFRelease(serial);
            }

            IOObjectRelease(service);
        }

    UIApplicationMain(argc, argv, [Cydia class]);
    [pool release];
}
