//
//  ViewController.m
//  WatchDogDemo02
//
//  Created by 无头骑士 GJ on 2020/3/27.
//  Copyright © 2020 无头骑士 GJ. All rights reserved.
//

#import "ViewController.h"

@interface ViewController ()

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [self performSelector: @selector(test)];
}
- (IBAction)watchDogDemo:(id)sender
{
    NSLog(@"watchDogDemo start");
    sleep(10);
    NSLog(@"watchDogDemo end");
}

@end
